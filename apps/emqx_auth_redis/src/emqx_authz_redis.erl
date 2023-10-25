%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authz_redis).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-behaviour(emqx_authz_source).

%% AuthZ Callbacks
-export([
    description/0,
    create/1,
    update/1,
    destroy/1,
    authorize/4
]).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-define(PLACEHOLDERS, [
    ?PH_CERT_CN_NAME,
    ?PH_CERT_SUBJECT,
    ?PH_PEERHOST,
    ?PH_CLIENTID,
    ?PH_USERNAME
]).

description() ->
    "AuthZ with Redis".

create(#{cmd := CmdStr} = Source) ->
    CmdTemplate = parse_cmd(CmdStr),
    ResourceId = emqx_authz_utils:make_resource_id(?MODULE),
    {ok, _Data} = emqx_authz_utils:create_resource(ResourceId, emqx_redis, Source),
    Source#{annotations => #{id => ResourceId}, cmd_template => CmdTemplate}.

update(#{cmd := CmdStr} = Source) ->
    CmdTemplate = parse_cmd(CmdStr),
    case emqx_authz_utils:update_resource(emqx_redis, Source) of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, Id} ->
            Source#{annotations => #{id => Id}, cmd_template => CmdTemplate}
    end.

destroy(#{annotations := #{id := Id}}) ->
    emqx_authz_utils:remove_resource(Id).

authorize(
    Client,
    Action,
    Topic,
    #{
        cmd_template := CmdTemplate,
        annotations := #{id := ResourceID}
    }
) ->
    Vars = emqx_authz_utils:vars_for_rule_query(Client, Action),
    Cmd = emqx_authz_utils:render_deep(CmdTemplate, Vars),
    case emqx_resource:simple_sync_query(ResourceID, {cmd, Cmd}) of
        {ok, Rows} ->
            do_authorize(Client, Action, Topic, Rows);
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "query_redis_error",
                reason => Reason,
                cmd => Cmd,
                resource_id => ResourceID
            }),
            nomatch
    end.

do_authorize(_Client, _Action, _Topic, []) ->
    nomatch;
do_authorize(Client, Action, Topic, [TopicFilterRaw, RuleEncoded | Tail]) ->
    try
        emqx_authz_rule:match(
            Client,
            Action,
            Topic,
            compile_rule(RuleEncoded, TopicFilterRaw)
        )
    of
        {matched, Permission} -> {matched, Permission};
        nomatch -> do_authorize(Client, Action, Topic, Tail)
    catch
        error:Reason:Stack ->
            ?SLOG(error, #{
                msg => "match_rule_error",
                reason => Reason,
                rule_encoded => RuleEncoded,
                topic_filter_raw => TopicFilterRaw,
                stacktrace => Stack
            }),
            do_authorize(Client, Action, Topic, Tail)
    end.

compile_rule(RuleBin, TopicFilterRaw) ->
    RuleRaw =
        maps:merge(
            #{
                <<"permission">> => <<"allow">>,
                <<"topic">> => TopicFilterRaw
            },
            parse_rule(RuleBin)
        ),
    case emqx_authz_rule_raw:parse_rule(RuleRaw) of
        {ok, {Permission, Action, Topics}} ->
            emqx_authz_rule:compile({Permission, all, Action, Topics});
        {error, Reason} ->
            error(Reason)
    end.

parse_cmd(Query) ->
    case emqx_redis_command:split(Query) of
        {ok, Cmd} ->
            ok = validate_cmd(Cmd),
            emqx_authz_utils:parse_deep(Cmd, ?PLACEHOLDERS);
        {error, Reason} ->
            error({invalid_redis_cmd, Reason, Query})
    end.

validate_cmd(Cmd) ->
    case
        emqx_auth_redis_validations:validate_command(
            [
                not_empty,
                {command_name, [<<"hmget">>, <<"hgetall">>]}
            ],
            Cmd
        )
    of
        ok -> ok;
        {error, Reason} -> error({invalid_redis_cmd, Reason, Cmd})
    end.

parse_rule(<<"publish">>) ->
    #{<<"action">> => <<"publish">>};
parse_rule(<<"subscribe">>) ->
    #{<<"action">> => <<"subscribe">>};
parse_rule(<<"all">>) ->
    #{<<"action">> => <<"all">>};
parse_rule(Bin) when is_binary(Bin) ->
    case emqx_utils_json:safe_decode(Bin, [return_maps]) of
        {ok, Map} when is_map(Map) ->
            maps:with([<<"qos">>, <<"action">>, <<"retain">>], Map);
        {ok, _} ->
            error({invalid_topic_rule, Bin, notamap});
        {error, Error} ->
            error({invalid_topic_rule, Bin, Error})
    end.
