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

-module(emqx_authn_ldap_bind).

-include_lib("emqx_auth/include/emqx_authn.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("eldap/include/eldap.hrl").

-behaviour(emqx_authn_provider).

-export([
    create/2,
    update/2,
    authenticate/2,
    destroy/1
]).

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

create(_AuthenticatorID, Config) ->
    emqx_authn_ldap:do_create(?MODULE, Config).

update(Config, State) ->
    emqx_authn_ldap:update(Config, State).

destroy(State) ->
    emqx_authn_ldap:destroy(State).

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(#{password := undefined}, _) ->
    {error, bad_username_or_password};
authenticate(
    #{password := _Password} = Credential,
    #{
        query_timeout := Timeout,
        resource_id := ResourceId
    } = _State
) ->
    case
        emqx_resource:simple_sync_query(
            ResourceId,
            {query, Credential, [], Timeout}
        )
    of
        {ok, []} ->
            ignore;
        {ok, [Entry]} ->
            case
                emqx_resource:simple_sync_query(
                    ResourceId,
                    {bind, Entry#eldap_entry.object_name, Credential}
                )
            of
                {ok, #{result := ok}} ->
                    {ok, #{is_superuser => false}};
                {ok, #{result := 'invalidCredentials'}} ->
                    ?TRACE_AUTHN_PROVIDER(error, "ldap_bind_failed", #{
                        resource => ResourceId,
                        reason => 'invalidCredentials'
                    }),
                    {error, bad_username_or_password};
                {error, Reason} ->
                    ?TRACE_AUTHN_PROVIDER(error, "ldap_bind_failed", #{
                        resource => ResourceId,
                        reason => Reason
                    }),
                    {error, bad_username_or_password}
            end;
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER(error, "ldap_query_failed", #{
                resource => ResourceId,
                timeout => Timeout,
                reason => Reason
            }),
            ignore
    end.
