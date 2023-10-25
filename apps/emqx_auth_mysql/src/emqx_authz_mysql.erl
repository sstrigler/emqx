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

-module(emqx_authz_mysql).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-behaviour(emqx_authz_source).

-define(PREPARE_KEY, ?MODULE).

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
    ?PH_USERNAME,
    ?PH_CLIENTID,
    ?PH_PEERHOST,
    ?PH_CERT_CN_NAME,
    ?PH_CERT_SUBJECT
]).

description() ->
    "AuthZ with Mysql".

create(#{query := SQL} = Source0) ->
    {PrepareSQL, TmplToken} = emqx_authz_utils:parse_sql(SQL, '?', ?PLACEHOLDERS),
    ResourceId = emqx_authz_utils:make_resource_id(?MODULE),
    Source = Source0#{prepare_statement => #{?PREPARE_KEY => PrepareSQL}},
    {ok, _Data} = emqx_authz_utils:create_resource(ResourceId, emqx_mysql, Source),
    Source#{annotations => #{id => ResourceId, tmpl_token => TmplToken}}.

update(#{query := SQL} = Source0) ->
    {PrepareSQL, TmplToken} = emqx_authz_utils:parse_sql(SQL, '?', ?PLACEHOLDERS),
    Source = Source0#{prepare_statement => #{?PREPARE_KEY => PrepareSQL}},
    case emqx_authz_utils:update_resource(emqx_mysql, Source) of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, Id} ->
            Source#{annotations => #{id => Id, tmpl_token => TmplToken}}
    end.

destroy(#{annotations := #{id := Id}}) ->
    emqx_authz_utils:remove_resource(Id).

authorize(
    Client,
    Action,
    Topic,
    #{
        annotations := #{
            id := ResourceID,
            tmpl_token := TmplToken
        }
    }
) ->
    Vars = emqx_authz_utils:vars_for_rule_query(Client, Action),
    RenderParams = emqx_authz_utils:render_sql_params(TmplToken, Vars),
    case
        emqx_resource:simple_sync_query(ResourceID, {prepared_query, ?PREPARE_KEY, RenderParams})
    of
        {ok, ColumnNames, Rows} ->
            do_authorize(Client, Action, Topic, ColumnNames, Rows);
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "query_mysql_error",
                reason => Reason,
                tmpl_token => TmplToken,
                params => RenderParams,
                resource_id => ResourceID
            }),
            nomatch
    end.

do_authorize(_Client, _Action, _Topic, _ColumnNames, []) ->
    nomatch;
do_authorize(Client, Action, Topic, ColumnNames, [Row | Tail]) ->
    try
        emqx_authz_rule:match(
            Client, Action, Topic, emqx_authz_utils:parse_rule_from_row(ColumnNames, Row)
        )
    of
        {matched, Permission} -> {matched, Permission};
        nomatch -> do_authorize(Client, Action, Topic, ColumnNames, Tail)
    catch
        error:Reason ->
            ?SLOG(error, #{
                msg => "match_rule_error",
                reason => Reason,
                rule => Row
            }),
            do_authorize(Client, Action, Topic, ColumnNames, Tail)
    end.
