%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_sso_ldap_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_dashboard/include/emqx_dashboard.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(LDAP_HOST, "ldap").
-define(LDAP_DEFAULT_PORT, 389).
-define(LDAP_USER, <<"viewer1">>).
-define(LDAP_USER_PASSWORD, <<"viewer1">>).
-define(LDAP_BASE_DN, <<"ou=dashboard,dc=emqx,dc=io">>).
-define(LDAP_FILTER_WITH_UID, <<"(uid=${username})">>).
%% there are more than one users in this group
-define(LDAP_FILTER_WITH_GROUP, <<"(ugroup=group1)">>).

-define(MOD_TAB, emqx_dashboard_sso).
-define(MOD_KEY_PATH, [dashboard, sso, ldap]).
-define(RESOURCE_GROUP, <<"emqx_dashboard_sso">>).

-import(emqx_mgmt_api_test_util, [request/2, request/3, uri/1, request_api/3]).

%% order matters
all() ->
    [
        t_bad_create,
        t_create,
        t_update,
        t_get,
        t_login_with_bad,
        t_first_login,
        t_next_login,
        t_more_than_one_user_matched,
        t_bad_update,
        t_delete
    ].

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    emqx_config:save_schema_mod_and_names(emqx_dashboard_schema),
    emqx_mgmt_api_test_util:init_suite([emqx_dashboard, emqx_dashboard_sso]),
    Config.

end_per_suite(_Config) ->
    All = emqx_dashboard_admin:all_users(),
    [emqx_dashboard_admin:remove_user(Name) || #{username := Name} <- All],
    emqx_mgmt_api_test_util:end_suite([emqx_conf, emqx_dashboard_sso]).

init_per_testcase(Case, Config) ->
    {ok, _} = emqx_cluster_rpc:start_link(),
    ?MODULE:Case({init, Config}),
    Config.

end_per_testcase(Case, Config) ->
    ?MODULE:Case({'end', Config}),
    case erlang:whereis(node()) of
        undefined ->
            ok;
        P ->
            erlang:unlink(P),
            erlang:exit(P, kill)
    end,
    ok.

t_bad_create({init, Config}) ->
    Config;
t_bad_create({'end', _}) ->
    ok;
t_bad_create(_) ->
    Path = uri(["sso", "ldap"]),
    ?assertMatch(
        {ok, 400, _},
        request(
            put,
            Path,
            ldap_config(#{
                <<"username">> => <<"invalid">>,
                <<"enable">> => true,
                <<"request_timeout">> => <<"1s">>
            })
        )
    ),
    ?assertMatch(#{backend := ldap}, emqx:get_config(?MOD_KEY_PATH, undefined)),
    check_running([]),
    ?assertMatch(
        [#{backend := <<"ldap">>, enable := true, running := false, last_error := _}], get_sso()
    ),

    emqx_dashboard_sso_manager:delete(ldap),

    ?retry(
        _Interval = 500,
        _NAttempts = 10,
        ?assertMatch([], emqx_resource_manager:list_group(?RESOURCE_GROUP))
    ),
    ok.

t_create({init, Config}) ->
    Config;
t_create({'end', _Config}) ->
    ok;
t_create(_) ->
    check_running([]),
    Path = uri(["sso", "ldap"]),
    {ok, 200, Result} = request(put, Path, ldap_config()),
    check_running([]),

    ?assertMatch(#{backend := ldap}, emqx:get_config(?MOD_KEY_PATH, undefined)),
    ?assertMatch([_], ets:tab2list(?MOD_TAB)),
    ?retry(
        _Interval = 500,
        _NAttempts = 10,
        ?assertMatch([_], emqx_resource_manager:list_group(?RESOURCE_GROUP))
    ),

    ?assertMatch(#{backend := <<"ldap">>, enable := false}, decode_json(Result)),
    ?assertMatch([#{backend := <<"ldap">>, enable := false}], get_sso()),
    ?assertNotEqual(undefined, emqx_dashboard_sso_manager:lookup_state(ldap)),
    ok.

t_update({init, Config}) ->
    Config;
t_update({'end', _Config}) ->
    ok;
t_update(_) ->
    Path = uri(["sso", "ldap"]),
    {ok, 200, Result} = request(put, Path, ldap_config(#{<<"enable">> => <<"true">>})),
    check_running([<<"ldap">>]),
    ?assertMatch(#{backend := <<"ldap">>, enable := true}, decode_json(Result)),
    ?assertMatch([#{backend := <<"ldap">>, enable := true}], get_sso()),
    ?assertNotEqual(undefined, emqx_dashboard_sso_manager:lookup_state(ldap)),
    ok.

t_get({init, Config}) ->
    Config;
t_get({'end', _Config}) ->
    ok;
t_get(_) ->
    Path = uri(["sso", "ldap"]),
    {ok, 200, Result} = request(get, Path),
    ?assertMatch(#{backend := <<"ldap">>, enable := true}, decode_json(Result)),

    NotExists = uri(["sso", "not"]),
    {ok, 400, _} = request(get, NotExists),
    ok.

t_login_with_bad({init, Config}) ->
    Config;
t_login_with_bad({'end', _Config}) ->
    ok;
t_login_with_bad(_) ->
    Path = uri(["sso", "login", "ldap"]),
    Req = #{
        <<"backend">> => <<"ldap">>,
        <<"username">> => <<"bad">>,
        <<"password">> => <<"password">>
    },
    {ok, 401, Result} = request(post, Path, Req),
    ?assertMatch(#{code := <<"BAD_USERNAME_OR_PWD">>}, decode_json(Result)),
    ok.

t_first_login({init, Config}) ->
    Config;
t_first_login({'end', _Config}) ->
    ok;
t_first_login(_) ->
    Path = uri(["sso", "login", "ldap"]),
    Req = #{
        <<"backend">> => <<"ldap">>,
        <<"username">> => ?LDAP_USER,
        <<"password">> => ?LDAP_USER_PASSWORD
    },
    %% this API is authorization-free
    {ok, 200, Result} = request_without_authorization(post, Path, Req),
    ?assertMatch(#{license := _, token := _, role := ?ROLE_VIEWER}, decode_json(Result)),
    ?assertMatch(
        [#?ADMIN{username = ?SSO_USERNAME(ldap, ?LDAP_USER)}],
        emqx_dashboard_admin:lookup_user(ldap, ?LDAP_USER)
    ),
    ok.

t_next_login({init, Config}) ->
    Config;
t_next_login({'end', _Config}) ->
    ok;
t_next_login(_) ->
    Path = uri(["sso", "login", "ldap"]),
    Req = #{
        <<"backend">> => <<"ldap">>,
        <<"username">> => ?LDAP_USER,
        <<"password">> => ?LDAP_USER_PASSWORD
    },
    {ok, 200, Result} = request(post, Path, Req),
    ?assertMatch(#{license := _, token := _}, decode_json(Result)),
    ok.

t_more_than_one_user_matched({init, Config}) ->
    emqx_logger:set_primary_log_level(error),
    Config;
t_more_than_one_user_matched({'end', _Config}) ->
    %% restore default config
    Path = uri(["sso", "ldap"]),
    {ok, 200, _} = request(put, Path, ldap_config(#{<<"enable">> => true})),
    ok;
t_more_than_one_user_matched(_) ->
    Path = uri(["sso", "ldap"]),
    %% change to query with ugroup=group1
    NewConfig = ldap_config(#{
        <<"enable">> => true,
        <<"base_dn">> => ?LDAP_BASE_DN,
        <<"filter">> => ?LDAP_FILTER_WITH_GROUP
    }),
    ?assertMatch({ok, 200, _}, request(put, Path, NewConfig)),
    check_running([<<"ldap">>]),
    Path1 = uri(["sso", "login", "ldap"]),
    Req = #{
        <<"backend">> => <<"ldap">>,
        <<"username">> => ?LDAP_USER,
        <<"password">> => ?LDAP_USER_PASSWORD
    },
    {ok, 401, Result} = request(post, Path1, Req),
    ?assertMatch(#{code := <<"BAD_USERNAME_OR_PWD">>}, decode_json(Result)),
    ok.

t_bad_update({init, Config}) ->
    Config;
t_bad_update({'end', _Config}) ->
    ok;
t_bad_update(_) ->
    Path = uri(["sso", "ldap"]),
    ?assertMatch(
        {ok, 400, _},
        request(
            put,
            Path,
            ldap_config(#{
                <<"username">> => <<"invalid">>,
                <<"enable">> => true,
                <<"request_timeout">> => <<"1s">>
            })
        )
    ),
    ?assertMatch(#{backend := ldap}, emqx:get_config(?MOD_KEY_PATH, undefined)),
    check_running([]),
    ?assertMatch(
        [#{backend := <<"ldap">>, enable := true, running := false, last_error := _}], get_sso()
    ),
    ok.

t_delete({init, Config}) ->
    Config;
t_delete({'end', _Config}) ->
    ok;
t_delete(_) ->
    Path = uri(["sso", "ldap"]),
    ?assertMatch({ok, 204, _}, request(delete, Path)),
    ?assertMatch({ok, 404, _}, request(delete, Path)),
    check_running([]),
    ok.

check_running(Expect) ->
    Path = uri(["sso", "running"]),
    %% this API is authorization-free
    {ok, Result} = request_api(get, Path, []),
    ?assertEqual(Expect, decode_json(Result)).

get_sso() ->
    Path = uri(["sso"]),
    {ok, 200, Result} = request(get, Path),
    decode_json(Result).

ldap_config() ->
    ldap_config(#{}).

ldap_config(Override) ->
    maps:merge(
        #{
            <<"backend">> => <<"ldap">>,
            <<"enable">> => <<"false">>,
            <<"server">> => ldap_server(),
            <<"base_dn">> => ?LDAP_BASE_DN,
            <<"filter">> => ?LDAP_FILTER_WITH_UID,
            <<"username">> => <<"cn=root,dc=emqx,dc=io">>,
            <<"password">> => <<"public">>,
            <<"pool_size">> => 8
        },
        Override
    ).

ldap_server() ->
    iolist_to_binary(io_lib:format("~s:~B", [?LDAP_HOST, ?LDAP_DEFAULT_PORT])).

decode_json(Data) ->
    BinJson = emqx_utils_json:decode(Data, [return_maps]),
    emqx_utils_maps:unsafe_atom_key_map(BinJson).

request_without_authorization(Method, Url, Body) ->
    Opts = #{compatible_mode => true, httpc_req_opts => [{body_format, binary}]},
    emqx_mgmt_api_test_util:request_api(Method, Url, [], [], Body, Opts).
