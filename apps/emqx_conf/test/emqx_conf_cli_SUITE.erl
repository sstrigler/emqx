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
-module(emqx_conf_cli_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("emqx_conf.hrl").
-import(emqx_config_SUITE, [prepare_conf_file/3]).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite([emqx_conf, emqx_auth, emqx_auth_redis]),
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite([emqx_conf, emqx_auth, emqx_auth_redis]).

t_load_config(Config) ->
    Authz = authorization,
    Conf = emqx_conf:get_raw([Authz]),
    %% set sources to []
    ConfBin = hocon_pp:do(#{<<"authorization">> => #{<<"sources">> => []}}, #{}),
    ConfFile = prepare_conf_file(?FUNCTION_NAME, ConfBin, Config),
    ok = emqx_conf_cli:conf(["load", "--replace", ConfFile]),
    ?assertEqual(#{<<"sources">> => []}, emqx_conf:get_raw([Authz])),

    ConfBin0 = hocon_pp:do(#{<<"authorization">> => Conf#{<<"sources">> => []}}, #{}),
    ConfFile0 = prepare_conf_file(?FUNCTION_NAME, ConfBin0, Config),
    ok = emqx_conf_cli:conf(["load", "--replace", ConfFile0]),
    ?assertEqual(Conf#{<<"sources">> => []}, emqx_conf:get_raw([Authz])),

    %% remove sources, it will reset to default file source.
    ConfBin1 = hocon_pp:do(#{<<"authorization">> => maps:remove(<<"sources">>, Conf)}, #{}),
    ConfFile1 = prepare_conf_file(?FUNCTION_NAME, ConfBin1, Config),
    ok = emqx_conf_cli:conf(["load", "--replace", ConfFile1]),
    Default = [emqx_authz_schema:default_authz()],
    ?assertEqual(Conf#{<<"sources">> => Default}, emqx_conf:get_raw([Authz])),
    %% reset
    ConfBin2 = hocon_pp:do(#{<<"authorization">> => Conf}, #{}),
    ConfFile2 = prepare_conf_file(?FUNCTION_NAME, ConfBin2, Config),
    ok = emqx_conf_cli:conf(["load", "--replace", ConfFile2]),
    ?assertEqual(
        Conf#{<<"sources">> => [emqx_authz_schema:default_authz()]},
        emqx_conf:get_raw([Authz])
    ),
    ?assertEqual({error, empty_hocon_file}, emqx_conf_cli:conf(["load", "non-exist-file"])),
    ok.

t_conflict_mix_conf(Config) ->
    case emqx_release:edition() of
        ce ->
            %% Don't fail if the test is run with emqx profile
            ok;
        ee ->
            AuthNInit = emqx_conf:get_raw([authentication]),
            Redis = #{
                <<"backend">> => <<"redis">>,
                <<"cmd">> => <<"HMGET mqtt_user:${username} password_hash salt">>,
                <<"enable">> => false,
                <<"mechanism">> => <<"password_based">>,
                %% password_hash_algorithm {name = sha256, salt_position = suffix}
                <<"redis_type">> => <<"single">>,
                <<"server">> => <<"127.0.0.1:6379">>
            },
            AuthN = #{<<"authentication">> => [Redis]},
            ConfBin = hocon_pp:do(AuthN, #{}),
            ConfFile = prepare_conf_file(?FUNCTION_NAME, ConfBin, Config),
            %% init with redis sources
            ok = emqx_conf_cli:conf(["load", "--replace", ConfFile]),
            ?assertMatch([Redis], emqx_conf:get_raw([authentication])),
            %% change redis type from single to cluster
            %% the server field will become servers field
            RedisCluster = maps:remove(<<"server">>, Redis#{
                <<"redis_type">> => cluster,
                <<"servers">> => [<<"127.0.0.1:6379">>]
            }),
            AuthN1 = AuthN#{<<"authentication">> => [RedisCluster]},
            ConfBin1 = hocon_pp:do(AuthN1, #{}),
            ConfFile1 = prepare_conf_file(?FUNCTION_NAME, ConfBin1, Config),
            {error, Reason} = emqx_conf_cli:conf(["load", "--merge", ConfFile1]),
            ?assertNotEqual(
                nomatch,
                binary:match(
                    Reason,
                    [<<"Tips: There may be some conflicts in the new configuration under">>]
                ),
                Reason
            ),
            %% use replace to change redis type from single to cluster
            ?assertMatch(ok, emqx_conf_cli:conf(["load", "--replace", ConfFile1])),
            %% clean up
            ConfBinInit = hocon_pp:do(#{<<"authentication">> => AuthNInit}, #{}),
            ConfFileInit = prepare_conf_file(?FUNCTION_NAME, ConfBinInit, Config),
            ok = emqx_conf_cli:conf(["load", "--replace", ConfFileInit]),
            ok
    end.

t_config_handler_hook_failed(Config) ->
    Listeners =
        #{
            <<"listeners">> => #{
                <<"ssl">> => #{
                    <<"default">> => #{
                        <<"ssl_options">> => #{
                            <<"keyfile">> => <<"">>
                        }
                    }
                }
            }
        },
    ConfBin = hocon_pp:do(Listeners, #{}),
    ConfFile = prepare_conf_file(?FUNCTION_NAME, ConfBin, Config),
    {error, Reason} = emqx_conf_cli:conf(["load", "--merge", ConfFile]),
    %% the hook failed with empty keyfile
    ?assertEqual(
        nomatch,
        binary:match(Reason, [
            <<"Tips: There may be some conflicts in the new configuration under">>
        ]),
        Reason
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(Reason, [
            <<"{bad_ssl_config,#{reason => pem_file_path_or_string_is_required">>
        ]),
        Reason
    ),
    ok.

t_load_readonly(Config) ->
    Base0 = base_conf(),
    Base1 = Base0#{<<"mqtt">> => emqx_conf:get_raw([mqtt])},
    lists:foreach(
        fun(Key) ->
            KeyBin = atom_to_binary(Key),
            Conf = emqx_conf:get_raw([Key]),
            ConfBin0 = hocon_pp:do(Base1#{KeyBin => Conf}, #{}),
            ConfFile0 = prepare_conf_file(?FUNCTION_NAME, ConfBin0, Config),
            ?assertEqual(
                {error, "update_readonly_keys_prohibited"},
                emqx_conf_cli:conf(["load", ConfFile0])
            ),
            %% reload etc/emqx.conf changed readonly keys
            ConfBin1 = hocon_pp:do(Base1#{KeyBin => changed(Key)}, #{}),
            ConfFile1 = prepare_conf_file(?FUNCTION_NAME, ConfBin1, Config),
            application:set_env(emqx, config_files, [ConfFile1]),
            ?assertMatch(ok, emqx_conf_cli:conf(["reload"])),
            %% Don't update readonly key
            ?assertEqual(Conf, emqx_conf:get_raw([Key]))
        end,
        ?READONLY_KEYS
    ),
    ok.

t_error_schema_check(Config) ->
    Base = #{
        %% bad multiplier
        <<"mqtt">> => #{<<"keepalive_multiplier">> => -1},
        <<"zones">> => #{<<"my-zone">> => #{<<"mqtt">> => #{<<"keepalive_multiplier">> => 10}}}
    },
    ConfBin0 = hocon_pp:do(Base, #{}),
    ConfFile0 = prepare_conf_file(?FUNCTION_NAME, ConfBin0, Config),
    ?assertMatch({error, _}, emqx_conf_cli:conf(["load", ConfFile0])),
    %% zones is not updated because of error
    ?assertEqual(#{}, emqx_config:get_raw([zones])),
    ok.

t_reload_etc_emqx_conf_not_persistent(Config) ->
    Mqtt = emqx_conf:get_raw([mqtt]),
    Base = base_conf(),
    Conf = Base#{<<"mqtt">> => Mqtt#{<<"keepalive_multiplier">> => 3}},
    ConfBin = hocon_pp:do(Conf, #{}),
    ConfFile = prepare_conf_file(?FUNCTION_NAME, ConfBin, Config),
    application:set_env(emqx, config_files, [ConfFile]),
    ok = emqx_conf_cli:conf(["reload"]),
    ?assertEqual(3, emqx:get_config([mqtt, keepalive_multiplier])),
    ?assertNotEqual(
        3,
        emqx_utils_maps:deep_get(
            [<<"mqtt">>, <<"keepalive_multiplier">>],
            emqx_config:read_override_conf(#{}),
            undefined
        )
    ),
    ok.

base_conf() ->
    #{
        <<"cluster">> => emqx_conf:get_raw([cluster]),
        <<"node">> => emqx_conf:get_raw([node])
    }.

changed(cluster) ->
    #{<<"name">> => <<"emqx-test">>};
changed(node) ->
    #{
        <<"name">> => <<"emqx-test@127.0.0.1">>,
        <<"cookie">> => <<"gokdfkdkf1122">>,
        <<"data_dir">> => <<"data">>
    };
changed(rpc) ->
    #{<<"mode">> => <<"sync">>}.
