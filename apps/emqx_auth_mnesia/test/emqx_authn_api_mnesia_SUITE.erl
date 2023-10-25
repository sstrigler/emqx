%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authn_api_mnesia_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(emqx_dashboard_api_test_helpers, [multipart_formdata_request/3]).
-import(emqx_mgmt_api_test_util, [request/3, uri/1]).

-include_lib("emqx_auth/include/emqx_authn.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(TCP_DEFAULT, 'tcp:default').

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_testcase(_Case, Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [?CONF_NS_ATOM],
        ?GLOBAL
    ),

    emqx_authn_test_lib:delete_authenticators(
        [listeners, tcp, default, ?CONF_NS_ATOM],
        ?TCP_DEFAULT
    ),
    Config.

end_per_testcase(_, Config) ->
    Config.

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [
            emqx,
            emqx_conf,
            emqx_auth,
            emqx_auth_mnesia,
            emqx_management,
            {emqx_dashboard, "dashboard.listeners.http { enable = true, bind = 18083 }"}
        ],
        #{
            work_dir => ?config(priv_dir, Config)
        }
    ),
    _ = emqx_common_test_http:create_default_app(),
    ?AUTHN:delete_chain(?GLOBAL),
    {ok, Chains} = ?AUTHN:list_chains(),
    ?assertEqual(length(Chains), 0),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    _ = emqx_common_test_http:delete_default_app(),
    ok = emqx_cth_suite:stop(?config(apps, Config)),
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_authenticator_users(_) ->
    test_authenticator_users([]).

t_authenticator_user(_) ->
    test_authenticator_user([]).

t_authenticator_import_users(_) ->
    test_authenticator_import_users([]).

% t_listener_authenticator_users(_) ->
%    test_authenticator_users(["listeners", ?TCP_DEFAULT]).

% t_listener_authenticator_user(_) ->
%    test_authenticator_user(["listeners", ?TCP_DEFAULT]).

% t_listener_authenticator_import_users(_) ->
%    test_authenticator_import_users(["listeners", ?TCP_DEFAULT]).

test_authenticator_users(PathPrefix) ->
    UsersUri = uri(PathPrefix ++ [?CONF_NS, "password_based:built_in_database", "users"]),

    {ok, 200, _} = request(
        post,
        uri(PathPrefix ++ [?CONF_NS]),
        emqx_authn_test_lib:built_in_database_example()
    ),

    {ok, Client} = emqtt:start_link(
        [
            {username, <<"u_event">>},
            {clientid, <<"c_event">>},
            {proto_ver, v5},
            {properties, #{'Session-Expiry-Interval' => 60}}
        ]
    ),

    process_flag(trap_exit, true),
    ?assertMatch({error, _}, emqtt:connect(Client)),
    timer:sleep(300),

    UsersUri0 = uri(PathPrefix ++ [?CONF_NS, "password_based:built_in_database", "status"]),
    {ok, 200, PageData0} = request(get, UsersUri0),
    case PathPrefix of
        [] ->
            #{
                <<"metrics">> := #{
                    <<"total">> := 1,
                    <<"success">> := 0,
                    <<"failed">> := 1
                }
            } = emqx_utils_json:decode(PageData0, [return_maps]);
        ["listeners", 'tcp:default'] ->
            #{
                <<"metrics">> := #{
                    <<"total">> := 1,
                    <<"success">> := 0,
                    <<"nomatch">> := 1
                }
            } = emqx_utils_json:decode(PageData0, [return_maps])
    end,

    InvalidUsers = [
        #{clientid => <<"u1">>, password => <<"p1">>},
        #{user_id => <<"u2">>},
        #{user_id => <<"u3">>, password => <<"p3">>, foobar => <<"foobar">>}
    ],

    lists:foreach(
        fun(User) -> {ok, 400, _} = request(post, UsersUri, User) end,
        InvalidUsers
    ),

    ValidUsers = [
        #{user_id => <<"u1">>, password => <<"p1">>},
        #{user_id => <<"u2">>, password => <<"p2">>, is_superuser => true},
        #{user_id => <<"u3">>, password => <<"p3">>}
    ],

    lists:foreach(
        fun(User) ->
            {ok, 201, UserData} = request(post, UsersUri, User),
            CreatedUser = emqx_utils_json:decode(UserData, [return_maps]),
            ?assertMatch(#{<<"user_id">> := _}, CreatedUser)
        end,
        ValidUsers
    ),

    {ok, Client1} = emqtt:start_link(
        [
            {username, <<"u1">>},
            {password, <<"p1">>},
            {clientid, <<"c_event">>},
            {proto_ver, v5},
            {properties, #{'Session-Expiry-Interval' => 60}}
        ]
    ),
    {ok, _} = emqtt:connect(Client1),
    timer:sleep(300),
    UsersUri01 = uri(PathPrefix ++ [?CONF_NS, "password_based:built_in_database", "status"]),
    {ok, 200, PageData01} = request(get, UsersUri01),
    case PathPrefix of
        [] ->
            #{
                <<"metrics">> := #{
                    <<"total">> := 2,
                    <<"success">> := 1,
                    <<"failed">> := 1
                }
            } = emqx_utils_json:decode(PageData01, [return_maps]);
        ["listeners", 'tcp:default'] ->
            #{
                <<"metrics">> := #{
                    <<"total">> := 2,
                    <<"success">> := 1,
                    <<"nomatch">> := 1
                }
            } = emqx_utils_json:decode(PageData01, [return_maps])
    end,

    {ok, 200, Page1Data} = request(get, UsersUri ++ "?page=1&limit=2"),

    #{
        <<"data">> := Page1Users,
        <<"meta">> :=
            #{
                <<"page">> := 1,
                <<"limit">> := 2,
                <<"count">> := 3
            }
    } =
        emqx_utils_json:decode(Page1Data, [return_maps]),

    {ok, 200, Page2Data} = request(get, UsersUri ++ "?page=2&limit=2"),

    #{
        <<"data">> := Page2Users,
        <<"meta">> :=
            #{
                <<"page">> := 2,
                <<"limit">> := 2,
                <<"count">> := 3
            }
    } = emqx_utils_json:decode(Page2Data, [return_maps]),

    ?assertEqual(2, length(Page1Users)),
    ?assertEqual(1, length(Page2Users)),

    ?assertEqual(
        [<<"u1">>, <<"u2">>, <<"u3">>],
        lists:usort([UserId || #{<<"user_id">> := UserId} <- Page1Users ++ Page2Users])
    ),

    {ok, 200, Super1Data} = request(get, UsersUri ++ "?page=1&limit=3&is_superuser=true"),

    #{
        <<"data">> := Super1Users,
        <<"meta">> :=
            #{
                <<"page">> := 1,
                <<"limit">> := 3,
                <<"count">> := 1
            }
    } = emqx_utils_json:decode(Super1Data, [return_maps]),

    ?assertEqual(
        [<<"u2">>],
        lists:usort([UserId || #{<<"user_id">> := UserId} <- Super1Users])
    ),

    {ok, 200, Super2Data} = request(get, UsersUri ++ "?page=1&limit=3&is_superuser=false"),

    #{
        <<"data">> := Super2Users,
        <<"meta">> :=
            #{
                <<"page">> := 1,
                <<"limit">> := 3,
                <<"count">> := 2
            }
    } = emqx_utils_json:decode(Super2Data, [return_maps]),

    ?assertEqual(
        [<<"u1">>, <<"u3">>],
        lists:usort([UserId || #{<<"user_id">> := UserId} <- Super2Users])
    ),

    ok.

test_authenticator_user(PathPrefix) ->
    UsersUri = uri(PathPrefix ++ [?CONF_NS, "password_based:built_in_database", "users"]),

    {ok, 200, _} = request(
        post,
        uri(PathPrefix ++ [?CONF_NS]),
        emqx_authn_test_lib:built_in_database_example()
    ),

    User = #{user_id => <<"u1">>, password => <<"p1">>},
    {ok, 201, _} = request(post, UsersUri, User),

    {ok, 404, _} = request(get, UsersUri ++ "/u123"),

    {ok, 409, _} = request(post, UsersUri, User),

    {ok, 200, UserData} = request(get, UsersUri ++ "/u1"),

    FetchedUser = emqx_utils_json:decode(UserData, [return_maps]),
    ?assertMatch(#{<<"user_id">> := <<"u1">>}, FetchedUser),
    ?assertNotMatch(#{<<"password">> := _}, FetchedUser),

    ValidUserUpdates = [
        #{password => <<"p1">>},
        #{password => <<"p1">>, is_superuser => true}
    ],

    lists:foreach(
        fun(UserUpdate) -> {ok, 200, _} = request(put, UsersUri ++ "/u1", UserUpdate) end,
        ValidUserUpdates
    ),

    InvalidUserUpdates = [#{user_id => <<"u1">>, password => <<"p1">>}],

    lists:foreach(
        fun(UserUpdate) -> {ok, 400, _} = request(put, UsersUri ++ "/u1", UserUpdate) end,
        InvalidUserUpdates
    ),

    {ok, 404, _} = request(delete, UsersUri ++ "/u123"),
    {ok, 204, _} = request(delete, UsersUri ++ "/u1").

test_authenticator_import_users(PathPrefix) ->
    ImportUri = uri(
        PathPrefix ++
            [?CONF_NS, "password_based:built_in_database", "import_users"]
    ),

    {ok, 200, _} = request(
        post,
        uri(PathPrefix ++ [?CONF_NS]),
        emqx_authn_test_lib:built_in_database_example()
    ),

    {ok, 400, _} = multipart_formdata_request(ImportUri, [], []),
    {ok, 400, _} = multipart_formdata_request(ImportUri, [], [
        {filenam, "user-credentials.json", <<>>}
    ]),

    Dir = code:lib_dir(emqx_auth, test),
    JSONFileName = filename:join([Dir, <<"data/user-credentials.json">>]),
    CSVFileName = filename:join([Dir, <<"data/user-credentials.csv">>]),

    {ok, JSONData} = file:read_file(JSONFileName),
    {ok, 204, _} = multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.json", JSONData}
    ]),

    {ok, CSVData} = file:read_file(CSVFileName),
    {ok, 204, _} = multipart_formdata_request(ImportUri, [], [
        {filename, "user-credentials.csv", CSVData}
    ]).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

request(Method, Url) ->
    request(Method, Url, []).
