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
-module(emqx_authn_ldap_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_auth/include/emqx_authn.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(LDAP_HOST, "ldap").
-define(LDAP_DEFAULT_PORT, 389).
-define(LDAP_RESOURCE, <<"emqx_authn_ldap_SUITE">>).

-define(PATH, [authentication]).
-define(ResourceID, <<"password_based:ldap">>).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_testcase(_, Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    Config.

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    case emqx_common_test_helpers:is_tcp_server_available(?LDAP_HOST, ?LDAP_DEFAULT_PORT) of
        true ->
            Apps = emqx_cth_suite:start([emqx, emqx_conf, emqx_auth, emqx_auth_ldap], #{
                work_dir => ?config(priv_dir, Config)
            }),
            {ok, _} = emqx_resource:create_local(
                ?LDAP_RESOURCE,
                ?AUTHN_RESOURCE_GROUP,
                emqx_ldap,
                ldap_config(),
                #{}
            ),
            [{apps, Apps} | Config];
        false ->
            {skip, no_ldap}
    end.

end_per_suite(Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    ok = emqx_resource:remove_local(?LDAP_RESOURCE),
    ok = emqx_cth_suite:stop(?config(apps, Config)).

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_create(_Config) ->
    AuthConfig = raw_ldap_auth_config(),

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    {ok, [#{provider := emqx_authn_ldap}]} = emqx_authn_chains:list_authenticators(?GLOBAL),
    emqx_authn_test_lib:delete_config(?ResourceID).

t_create_invalid(_Config) ->
    AuthConfig = raw_ldap_auth_config(),

    InvalidConfigs =
        [
            AuthConfig#{<<"server">> => <<"unknownhost:3333">>},
            AuthConfig#{<<"password">> => <<"wrongpass">>}
        ],

    lists:foreach(
        fun(Config) ->
            {ok, _} = emqx:update_config(
                ?PATH,
                {create_authenticator, ?GLOBAL, Config}
            ),
            emqx_authn_test_lib:delete_config(?ResourceID),
            ?assertEqual(
                {error, {not_found, {chain, ?GLOBAL}}},
                emqx_authn_chains:list_authenticators(?GLOBAL)
            )
        end,
        InvalidConfigs
    ).

t_authenticate(_Config) ->
    ok = lists:foreach(
        fun(Sample) ->
            ct:pal("test_user_auth sample: ~p", [Sample]),
            test_user_auth(Sample)
        end,
        user_seeds()
    ).

test_user_auth(#{
    credentials := Credentials0,
    config_params := SpecificConfigParams,
    result := Result
}) ->
    AuthConfig = maps:merge(raw_ldap_auth_config(), SpecificConfigParams),

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    Credentials = Credentials0#{
        listener => 'tcp:default',
        protocol => mqtt
    },

    ?assertEqual(Result, emqx_access_control:authenticate(Credentials)),

    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ).

t_destroy(_Config) ->
    AuthConfig = raw_ldap_auth_config(),

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    {ok, [#{provider := emqx_authn_ldap, state := State}]} =
        emqx_authn_chains:list_authenticators(?GLOBAL),

    {ok, _} = emqx_authn_ldap:authenticate(
        #{
            username => <<"mqttuser0001">>,
            password => <<"mqttuser0001">>
        },
        State
    ),

    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),

    % Authenticator should not be usable anymore
    ?assertMatch(
        ignore,
        emqx_authn_ldap:authenticate(
            #{
                username => <<"mqttuser0001">>,
                password => <<"mqttuser0001">>
            },
            State
        )
    ).

t_update(_Config) ->
    CorrectConfig = raw_ldap_auth_config(),
    IncorrectConfig =
        CorrectConfig#{
            <<"base_dn">> => <<"ou=testdevice,dc=emqx,dc=io">>
        },

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, IncorrectConfig}
    ),

    {error, _} = emqx_access_control:authenticate(
        #{
            username => <<"mqttuser0001">>,
            password => <<"mqttuser0001">>,
            listener => 'tcp:default',
            protocol => mqtt
        }
    ),

    % We update with config with correct query, provider should update and work properly
    {ok, _} = emqx:update_config(
        ?PATH,
        {update_authenticator, ?GLOBAL, <<"password_based:ldap">>, CorrectConfig}
    ),

    {ok, _} = emqx_access_control:authenticate(
        #{
            username => <<"mqttuser0001">>,
            password => <<"mqttuser0001">>,
            listener => 'tcp:default',
            protocol => mqtt
        }
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

raw_ldap_auth_config() ->
    #{
        <<"mechanism">> => <<"password_based">>,
        <<"backend">> => <<"ldap">>,
        <<"server">> => ldap_server(),
        <<"base_dn">> => <<"uid=${username},ou=testdevice,dc=emqx,dc=io">>,
        <<"username">> => <<"cn=root,dc=emqx,dc=io">>,
        <<"password">> => <<"public">>,
        <<"pool_size">> => 8
    }.

user_seeds() ->
    New = fun(Username, Password, Result) ->
        #{
            credentials => #{
                username => Username,
                password => Password
            },
            config_params => #{},
            result => Result
        }
    end,
    Valid =
        lists:map(
            fun(Idx) ->
                Username = erlang:iolist_to_binary(io_lib:format("mqttuser000~b", [Idx])),
                New(Username, Username, {ok, #{is_superuser => false}})
            end,
            lists:seq(1, 5)
        ),
    [
        %% Not exists
        New(<<"notexists">>, <<"notexists">>, {error, not_authorized}),
        %% Wrong Password
        New(<<"mqttuser0001">>, <<"wrongpassword">>, {error, bad_username_or_password}),
        %% Disabled
        New(<<"mqttuser0006">>, <<"mqttuser0006">>, {error, user_disabled}),
        %% IsSuperuser
        New(<<"mqttuser0007">>, <<"mqttuser0007">>, {ok, #{is_superuser => true}}),
        New(<<"mqttuser0008 (test)">>, <<"mqttuser0008 (test)">>, {ok, #{is_superuser => true}}),
        New(
            <<"mqttuser0009 \\\\test\\\\">>,
            <<"mqttuser0009 \\\\test\\\\">>,
            {ok, #{is_superuser => true}}
        )
        | Valid
    ].

ldap_server() ->
    iolist_to_binary(io_lib:format("~s:~B", [?LDAP_HOST, ?LDAP_DEFAULT_PORT])).

ldap_config() ->
    emqx_ldap_SUITE:ldap_config([]).
