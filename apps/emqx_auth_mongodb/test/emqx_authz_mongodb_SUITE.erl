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

-module(emqx_authz_mongodb_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_auth/include/emqx_authz.hrl").
-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-define(MONGO_HOST, "mongo").
-define(MONGO_CLIENT, 'emqx_authz_mongo_SUITE_client').

all() ->
    emqx_authz_test_lib:all_with_table_case(?MODULE, t_run_case, cases()).

groups() ->
    emqx_authz_test_lib:table_groups(t_run_case, cases()).

init_per_suite(Config) ->
    case emqx_common_test_helpers:is_tcp_server_available(?MONGO_HOST, ?MONGO_DEFAULT_PORT) of
        true ->
            Apps = emqx_cth_suite:start(
                [
                    emqx,
                    {emqx_conf,
                        "authorization.no_match = deny, authorization.cache.enable = false"},
                    emqx_auth,
                    emqx_auth_mongodb
                ],
                #{work_dir => ?config(priv_dir, Config)}
            ),
            [{suite_apps, Apps} | Config];
        false ->
            {skip, no_mongo}
    end.

end_per_suite(Config) ->
    ok = emqx_authz_test_lib:restore_authorizers(),
    emqx_cth_suite:stop(?config(suite_apps, Config)).

init_per_group(Group, Config) ->
    [{test_case, emqx_authz_test_lib:get_case(Group, cases())} | Config].
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    {ok, _} = mc_worker_api:connect(mongo_config()),
    ok = emqx_authz_test_lib:reset_authorizers(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    _ = emqx_authz:set_feature_available(rich_actions, true),
    ok = reset_samples(),
    ok = mc_worker_api:disconnect(?MONGO_CLIENT).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_run_case(Config) ->
    Case = ?config(test_case, Config),
    ok = setup_source_data(Case),
    ok = setup_authz_source(Case),
    ok = emqx_authz_test_lib:run_checks(Case).

%%------------------------------------------------------------------------------
%% Cases
%%------------------------------------------------------------------------------

cases() ->
    [
        #{
            name => base_publish,
            records => [
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"subscribe">>,
                    <<"topic">> => <<"b">>,
                    <<"permission">> => <<"allow">>
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"all">>,
                    <<"topics">> => [<<"c">>, <<"d">>],
                    <<"permission">> => <<"allow">>
                }
            ],
            filter => #{<<"username">> => <<"${username}">>},
            checks => [
                {allow, ?AUTHZ_PUBLISH, <<"a">>},
                {deny, ?AUTHZ_SUBSCRIBE, <<"a">>},

                {deny, ?AUTHZ_PUBLISH, <<"b">>},
                {allow, ?AUTHZ_SUBSCRIBE, <<"b">>},

                {allow, ?AUTHZ_PUBLISH, <<"c">>},
                {allow, ?AUTHZ_SUBSCRIBE, <<"c">>},
                {allow, ?AUTHZ_PUBLISH, <<"d">>},
                {allow, ?AUTHZ_SUBSCRIBE, <<"d">>}
            ]
        },
        #{
            name => filter_works,
            records => [
                #{
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            filter => #{<<"username">> => <<"${username}">>},
            checks => [
                {deny, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => invalid_rich_rules,
            features => [rich_actions],
            records => [
                #{
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>,
                    <<"qos">> => <<"1,2,3">>
                },
                #{
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>,
                    <<"retain">> => <<"yes">>
                }
            ],
            filter => #{},
            checks => [
                {deny, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => invalid_rules,
            records => [
                #{
                    <<"action">> => <<"publis">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            filter => #{},
            checks => [
                {deny, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => rule_by_clientid_cn_dn_peerhost,
            records => [
                #{
                    <<"cn">> => <<"cn">>,
                    <<"dn">> => <<"dn">>,
                    <<"clientid">> => <<"clientid">>,
                    <<"peerhost">> => <<"127.0.0.1">>,
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            client_info => #{
                cn => <<"cn">>,
                dn => <<"dn">>
            },
            filter => #{
                <<"cn">> => <<"${cert_common_name}">>,
                <<"dn">> => <<"${cert_subject}">>,
                <<"clientid">> => <<"${clientid}">>,
                <<"peerhost">> => <<"${peerhost}">>
            },
            checks => [
                {allow, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => topics_literal_wildcard_variable,
            records => [
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topics">> => [
                        <<"t/${username}">>,
                        <<"t/${clientid}">>,
                        <<"t1/#">>,
                        <<"t2/+">>,
                        <<"eq t3/${username}">>
                    ]
                }
            ],
            filter => #{<<"username">> => <<"${username}">>},
            checks => [
                {allow, ?AUTHZ_PUBLISH, <<"t/username">>},
                {allow, ?AUTHZ_PUBLISH, <<"t/clientid">>},
                {allow, ?AUTHZ_PUBLISH, <<"t1/a/b">>},
                {allow, ?AUTHZ_PUBLISH, <<"t2/a">>},
                {allow, ?AUTHZ_PUBLISH, <<"t3/${username}">>},
                {deny, ?AUTHZ_PUBLISH, <<"t3/username">>}
            ]
        },
        #{
            name => qos_retain_in_query_result,
            features => [rich_actions],
            records => [
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"a">>,
                    <<"qos">> => 1,
                    <<"retain">> => true
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"b">>,
                    <<"qos">> => <<"1">>,
                    <<"retain">> => <<"true">>
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"c">>,
                    <<"qos">> => <<"1,2">>,
                    <<"retain">> => 1
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"d">>,
                    <<"qos">> => [1, 2],
                    <<"retain">> => <<"1">>
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"e">>,
                    <<"qos">> => [1, 2],
                    <<"retain">> => <<"all">>
                },
                #{
                    <<"username">> => <<"username">>,
                    <<"action">> => <<"publish">>,
                    <<"permission">> => <<"allow">>,
                    <<"topic">> => <<"f">>,
                    <<"qos">> => null,
                    <<"retain">> => null
                }
            ],
            filter => #{<<"username">> => <<"${username}">>},
            checks => [
                {allow, ?AUTHZ_PUBLISH(1, true), <<"a">>},
                {deny, ?AUTHZ_PUBLISH(1, false), <<"a">>},

                {allow, ?AUTHZ_PUBLISH(1, true), <<"b">>},
                {deny, ?AUTHZ_PUBLISH(1, false), <<"b">>},
                {deny, ?AUTHZ_PUBLISH(2, false), <<"b">>},

                {allow, ?AUTHZ_PUBLISH(2, true), <<"c">>},
                {deny, ?AUTHZ_PUBLISH(2, false), <<"c">>},
                {deny, ?AUTHZ_PUBLISH(0, true), <<"c">>},

                {allow, ?AUTHZ_PUBLISH(2, true), <<"d">>},
                {deny, ?AUTHZ_PUBLISH(0, true), <<"d">>},

                {allow, ?AUTHZ_PUBLISH(1, false), <<"e">>},
                {allow, ?AUTHZ_PUBLISH(1, true), <<"e">>},
                {deny, ?AUTHZ_PUBLISH(0, false), <<"e">>},

                {allow, ?AUTHZ_PUBLISH, <<"f">>},
                {deny, ?AUTHZ_SUBSCRIBE, <<"f">>}
            ]
        },
        #{
            name => nonbin_values_in_client_info,
            records => [
                #{
                    <<"username">> => <<"username">>,
                    <<"clientid">> => <<"clientid">>,
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            client_info => #{
                username => "username",
                clientid => clientid
            },
            filter => #{<<"username">> => <<"${username}">>, <<"clientid">> => <<"${clientid}">>},
            checks => [
                {allow, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => invalid_query,
            records => [
                #{
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            filter => #{<<"$in">> => #{<<"a">> => 1}},
            checks => [
                {deny, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        },
        #{
            name => complex_query,
            records => [
                #{
                    <<"a">> => #{<<"u">> => <<"clientid">>, <<"c">> => [<<"cn">>, <<"dn">>]},
                    <<"action">> => <<"publish">>,
                    <<"topic">> => <<"a">>,
                    <<"permission">> => <<"allow">>
                }
            ],
            client_info => #{
                cn => <<"cn">>,
                dn => <<"dn">>
            },
            filter => #{
                <<"a">> => #{
                    <<"u">> => <<"${clientid}">>,
                    <<"c">> => [<<"${cert_common_name}">>, <<"${cert_subject}">>]
                }
            },
            checks => [
                {allow, ?AUTHZ_PUBLISH, <<"a">>}
            ]
        }
    ].

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

reset_samples() ->
    {true, _} = mc_worker_api:delete(?MONGO_CLIENT, <<"acl">>, #{}),
    ok.

setup_source_data(#{records := Records}) ->
    {{true, _}, _} = mc_worker_api:insert(?MONGO_CLIENT, <<"acl">>, Records),
    ok.

setup_authz_source(#{filter := Filter}) ->
    setup_config(
        #{
            <<"filter">> => Filter
        }
    ).

setup_config(SpecialParams) ->
    emqx_authz_test_lib:setup_config(
        raw_mongo_authz_config(),
        SpecialParams
    ).

raw_mongo_authz_config() ->
    #{
        <<"type">> => <<"mongodb">>,
        <<"enable">> => <<"true">>,

        <<"mongo_type">> => <<"single">>,
        <<"database">> => <<"mqtt">>,
        <<"collection">> => <<"acl">>,
        <<"server">> => mongo_server(),

        <<"filter">> => #{<<"username">> => <<"${username}">>}
    }.

mongo_server() ->
    iolist_to_binary(io_lib:format("~s", [?MONGO_HOST])).

mongo_config() ->
    [
        {database, <<"mqtt">>},
        {host, ?MONGO_HOST},
        {port, ?MONGO_DEFAULT_PORT},
        {register, ?MONGO_CLIENT}
    ].

start_apps(Apps) ->
    lists:foreach(fun application:ensure_all_started/1, Apps).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
