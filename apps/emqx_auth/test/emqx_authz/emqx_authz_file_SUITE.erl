%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authz_file_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_auth/include/emqx_authz.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(RAW_SOURCE, #{
    <<"type">> => <<"file">>,
    <<"enable">> => true,
    <<"rules">> =>
        <<
            "{allow,{username,\"^dashboard?\"},subscribe,[\"$SYS/#\"]}."
            "\n{allow,{ipaddr,\"127.0.0.1\"},all,[\"$SYS/#\",\"#\"]}."
        >>
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_testcase(TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx_conf, "authorization.no_match = deny, authorization.cache.enable = false"},
            emqx,
            emqx_auth
        ],
        #{work_dir => filename:join(?config(priv_dir, Config), TestCase)}
    ),
    [{tc_apps, Apps} | Config].

end_per_testcase(_TestCase, Config) ->
    emqx_cth_suite:stop(?config(tc_apps, Config)),
    _ = emqx_authz:set_feature_available(rich_actions, true).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_ok(_Config) ->
    ClientInfo = emqx_authz_test_lib:base_client_info(),

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_rich_actions(_Config) ->
    ClientInfo = emqx_authz_test_lib:base_client_info(),

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> =>
            <<"{allow, {user, \"username\"}, {publish, [{qos, 1}, {retain, false}]}, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH(1, false), <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH(0, false), <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_no_rich_actions(_Config) ->
    _ = emqx_authz:set_feature_available(rich_actions, false),
    ?assertMatch(
        {error, {pre_config_update, emqx_authz, {invalid_authorization_action, _}}},
        emqx_authz:update(?CMD_REPLACE, [
            ?RAW_SOURCE#{
                <<"rules">> =>
                    <<"{allow, {user, \"username\"}, {publish, [{qos, 1}, {retain, false}]}, [\"t\"]}.">>
            }
        ])
    ).

t_superuser(_Config) ->
    ClientInfo =
        emqx_authz_test_lib:client_info(#{is_superuser => true}),

    %% no rules apply to superuser
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{deny, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_invalid_file(_Config) ->
    ?assertMatch(
        {error,
            {pre_config_update, emqx_authz,
                {bad_acl_file_content, {1, erl_parse, ["syntax error before: ", "term"]}}}},
        emqx_authz:update(?CMD_REPLACE, [?RAW_SOURCE#{<<"rules">> => <<"{{invalid term">>}])
    ).

t_update(_Config) ->
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertMatch(
        {error, _},
        emqx_authz:update(
            {?CMD_REPLACE, file},
            ?RAW_SOURCE#{<<"rules">> => <<"{{invalid term">>}
        )
    ),

    ?assertMatch(
        {ok, _},
        emqx_authz:update(
            {?CMD_REPLACE, file}, ?RAW_SOURCE
        )
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

setup_config(SpecialParams) ->
    emqx_authz_test_lib:setup_config(
        ?RAW_SOURCE,
        SpecialParams
    ).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
