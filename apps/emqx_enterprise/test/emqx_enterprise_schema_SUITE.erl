%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_enterprise_schema_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_testcase(t_audit_log_conf, Config) ->
    Apps = emqx_cth_suite:start(
        [
            emqx_enterprise,
            {emqx_conf, #{schema_mod => emqx_enterprise_schema}}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(t_audit_log_conf, Config) ->
    Apps = ?config(apps, Config),
    ok = emqx_cth_suite:stop(Apps),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_namespace(_Config) ->
    ?assertEqual(
        emqx_conf_schema:namespace(),
        emqx_enterprise_schema:namespace()
    ).

t_roots(_Config) ->
    EnterpriseRoots = emqx_enterprise_schema:roots(),
    ?assertMatch({license, _}, lists:keyfind(license, 1, EnterpriseRoots)).

t_fields(_Config) ->
    CeFields = emqx_conf_schema:fields("node"),
    EeFields = emqx_enterprise_schema:fields("node"),
    ?assertEqual(length(CeFields), length(EeFields)),
    lists:foreach(
        fun({{CeName, CeSchema}, {EeName, EeSchema}}) ->
            ?assertEqual(CeName, EeName),
            case CeName of
                "applications" ->
                    ok;
                _ ->
                    ?assertEqual({CeName, CeSchema}, {EeName, EeSchema})
            end
        end,
        lists:zip(CeFields, EeFields)
    ).

t_translations(_Config) ->
    [Root | _] = emqx_enterprise_schema:translations(),
    ?assertEqual(
        emqx_conf_schema:translation(Root),
        emqx_enterprise_schema:translation(Root)
    ).

t_audit_log_conf(_Config) ->
    FileExpect = #{
        <<"enable">> => true,
        <<"formatter">> => <<"text">>,
        <<"level">> => <<"warning">>,
        <<"rotation_count">> => 10,
        <<"rotation_size">> => <<"50MB">>,
        <<"time_offset">> => <<"system">>,
        <<"path">> => <<"log/emqx.log">>
    },
    ExpectLog1 = #{
        <<"console">> =>
            #{
                <<"enable">> => false,
                <<"formatter">> => <<"text">>,
                <<"level">> => <<"warning">>,
                <<"time_offset">> => <<"system">>
            },
        <<"file">> =>
            #{<<"default">> => FileExpect},
        <<"audit">> =>
            #{
                <<"enable">> => false,
                <<"level">> => <<"info">>,
                <<"path">> => <<"log/audit.log">>,
                <<"rotation_count">> => 10,
                <<"rotation_size">> => <<"50MB">>,
                <<"time_offset">> => <<"system">>
            }
    },
    ?assertEqual(ExpectLog1, emqx_conf:get_raw([<<"log">>])),
    ok.
