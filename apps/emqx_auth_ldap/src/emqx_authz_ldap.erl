%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authz_ldap).

-include_lib("emqx/include/logger.hrl").
-include_lib("eldap/include/eldap.hrl").

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

%%------------------------------------------------------------------------------
%% AuthZ Callbacks
%%------------------------------------------------------------------------------

description() ->
    "AuthZ with LDAP".

create(Source) ->
    ResourceId = emqx_authz_utils:make_resource_id(?MODULE),
    {ok, _Data} = emqx_authz_utils:create_resource(ResourceId, emqx_ldap, Source),
    Annotations = new_annotations(#{id => ResourceId}, Source),
    Source#{annotations => Annotations}.

update(Source) ->
    case emqx_authz_utils:update_resource(emqx_ldap, Source) of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, Id} ->
            Annotations = new_annotations(#{id => Id}, Source),
            Source#{annotations => Annotations}
    end.

destroy(#{annotations := #{id := Id}}) ->
    emqx_authz_utils:remove_resource(Id).

authorize(
    Client,
    Action,
    Topic,
    #{
        query_timeout := QueryTimeout,
        annotations := #{id := ResourceID} = Annotations
    }
) ->
    Attrs = select_attrs(Action, Annotations),
    case emqx_resource:simple_sync_query(ResourceID, {query, Client, Attrs, QueryTimeout}) of
        {ok, []} ->
            nomatch;
        {ok, [Entry]} ->
            do_authorize(Action, Topic, Attrs, Entry);
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "ldap_query_failed",
                reason => emqx_utils:redact(Reason),
                resource_id => ResourceID
            }),
            nomatch
    end.

do_authorize(Action, Topic, [Attr | T], Entry) ->
    Topics = proplists:get_value(Attr, Entry#eldap_entry.attributes, []),
    case match_topic(Topic, Topics) of
        true ->
            {matched, allow};
        false ->
            do_authorize(Action, Topic, T, Entry)
    end;
do_authorize(_Action, _Topic, [], _Entry) ->
    nomatch.

new_annotations(Init, Source) ->
    State = maps:with(
        [query_timeout, publish_attribute, subscribe_attribute, all_attribute], Source
    ),
    maps:merge(Init, State).

select_attrs(#{action_type := publish}, #{publish_attribute := Pub, all_attribute := All}) ->
    [Pub, All];
select_attrs(_, #{subscribe_attribute := Sub, all_attribute := All}) ->
    [Sub, All].

match_topic(Target, Topics) ->
    lists:any(
        fun(Topic) ->
            emqx_topic:match(Target, erlang:list_to_binary(Topic))
        end,
        Topics
    ).
