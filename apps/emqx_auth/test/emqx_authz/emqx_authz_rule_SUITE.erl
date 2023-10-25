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

-module(emqx_authz_rule_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-define(CLIENT_INFO_BASE, #{
    clientid => <<"test">>,
    username => <<"test">>,
    peerhost => {127, 0, 0, 1},
    zone => default,
    listener => {tcp, default}
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    ok = emqx_common_test_helpers:start_apps(
        [emqx_conf, emqx_auth],
        fun set_special_configs/1
    ),
    Config.

end_per_suite(_Config) ->
    {ok, _} = emqx:update_config(
        [authorization],
        #{
            <<"no_match">> => <<"allow">>,
            <<"cache">> => #{<<"enable">> => <<"true">>},
            <<"sources">> => []
        }
    ),
    emqx_common_test_helpers:stop_apps([emqx_auth, emqx_conf]),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.
end_per_testcase(_TestCase, _Config) ->
    _ = emqx_authz:set_feature_available(rich_actions, true),
    ok.

set_special_configs(emqx_auth) ->
    {ok, _} = emqx:update_config([authorization, cache, enable], false),
    {ok, _} = emqx:update_config([authorization, no_match], deny),
    {ok, _} = emqx:update_config([authorization, sources], []),
    ok;
set_special_configs(_App) ->
    ok.

t_compile(_) ->
    ?assertEqual({deny, all, all, [['#']]}, emqx_authz_rule:compile({deny, all})),

    ?assertEqual(
        {allow, {ipaddr, {{127, 0, 0, 1}, {127, 0, 0, 1}, 32}}, all, [{eq, ['#']}, {eq, ['+']}]},
        emqx_authz_rule:compile({allow, {ipaddr, "127.0.0.1"}, all, [{eq, "#"}, {eq, "+"}]})
    ),

    ?assertEqual(
        {allow,
            {ipaddrs, [
                {{127, 0, 0, 1}, {127, 0, 0, 1}, 32},
                {{192, 168, 1, 0}, {192, 168, 1, 255}, 24}
            ]},
            subscribe, [{pattern, [{var, [<<"clientid">>]}]}]},
        emqx_authz_rule:compile(
            {allow, {ipaddrs, ["127.0.0.1", "192.168.1.0/24"]}, subscribe, [?PH_S_CLIENTID]}
        )
    ),

    ?assertEqual(
        {allow, {'and', [{clientid, {eq, <<"test">>}}, {username, {eq, <<"test">>}}]}, publish, [
            [<<"topic">>, <<"test">>]
        ]},
        emqx_authz_rule:compile(
            {allow, {'and', [{client, "test"}, {user, "test"}]}, publish, ["topic/test"]}
        )
    ),

    ?assertMatch(
        {allow,
            {'or', [
                {username, {re_pattern, _, _, _, _}},
                {clientid, {re_pattern, _, _, _, _}}
            ]},
            publish, [
                {pattern, [{var, [<<"username">>]}]}, {pattern, [{var, [<<"clientid">>]}]}
            ]},
        emqx_authz_rule:compile(
            {allow,
                {'or', [
                    {username, {re, "^test"}},
                    {clientid, {re, "test?"}}
                ]},
                publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, publish, [
            {pattern, [{str, <<"t/foo">>}, {var, [<<"username">>]}, {str, <<"boo">>}]}
        ]},
        emqx_authz_rule:compile({allow, {username, "test"}, publish, ["t/foo${username}boo"]})
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}},
            #{action_type => publish, qos => [0, 1, 2], retain => all}, [[<<"topic">>, <<"test">>]]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {publish, [{retain, all}]}, ["topic/test"]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, #{action_type => publish, qos => [1], retain => true},
            [
                [<<"topic">>, <<"test">>]
            ]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {publish, [{qos, 1}, {retain, true}]}, ["topic/test"]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, #{action_type => subscribe, qos => [1, 2]}, [
            [<<"topic">>, <<"test">>]
        ]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {subscribe, [{qos, 1}, {qos, 2}]}, ["topic/test"]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, #{action_type => subscribe, qos => [1]}, [
            [<<"topic">>, <<"test">>]
        ]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {subscribe, [{qos, 1}]}, ["topic/test"]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, #{action_type => all, qos => [2], retain => true}, [
            [<<"topic">>, <<"test">>]
        ]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
        )
    ),

    ok.

t_compile_ce(_Config) ->
    _ = emqx_authz:set_feature_available(rich_actions, false),

    ?assertThrow(
        {invalid_authorization_action, _},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
        )
    ),

    ?assertEqual(
        {allow, {username, {eq, <<"test">>}}, all, [[<<"topic">>, <<"test">>]]},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, all, ["topic/test"]}
        )
    ).

t_match(_) ->
    ?assertEqual(
        {matched, deny},
        emqx_authz_rule:match(
            client_info(),
            #{action_type => subscribe, qos => 0},
            <<"#">>,
            emqx_authz_rule:compile({deny, all})
        )
    ),

    ?assertEqual(
        {matched, deny},
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => subscribe, qos => 0},
            <<"+">>,
            emqx_authz_rule:compile({deny, all})
        )
    ),

    ?assertEqual(
        {matched, deny},
        emqx_authz_rule:match(
            client_info(#{username => <<"fake">>}),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile({deny, all})
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(),
            #{action_type => subscribe, qos => 0},
            <<"#">>,
            emqx_authz_rule:compile({allow, {ipaddr, "127.0.0.1"}, all, [{eq, "#"}, {eq, "+"}]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, {ipaddr, "127.0.0.1"}, all, [{eq, "#"}, {eq, "+"}]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => subscribe, qos => 0},
            <<"#">>,
            emqx_authz_rule:compile({allow, {ipaddr, "127.0.0.1"}, all, [{eq, "#"}, {eq, "+"}]})
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(),
            #{action_type => subscribe, qos => 0},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow, {ipaddrs, ["127.0.0.1", "192.168.1.0/24"]}, subscribe, [?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => subscribe, qos => 0},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow, {ipaddrs, ["127.0.0.1", "192.168.1.0/24"]}, subscribe, [?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {ipaddrs, ["127.0.0.1", "192.168.1.0/24"]}, subscribe, [?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(),
            #{action_type => publish, qos => 0, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {'and', [{client, "test"}, {user, "test"}]}, publish, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => publish, qos => 0, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {'and', [{client, "test"}, {user, "test"}]}, publish, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{username => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {'and', [{client, "test"}, {user, "test"}]}, publish, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {'and', [{client, "test"}, {user, "test"}]}, publish, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(),
            #{action_type => publish, qos => 0, retain => false},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{peerhost => {192, 168, 1, 10}}),
            #{action_type => publish, qos => 0, retain => false},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{username => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{username => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"fake">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"test">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"fake">>,
            emqx_authz_rule:compile(
                {allow,
                    {'or', [
                        {username, {re, "^test"}},
                        {clientid, {re, "test?"}}
                    ]},
                    publish, [?PH_S_USERNAME, ?PH_S_CLIENTID]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(),
            #{action_type => publish, qos => 0, retain => false},
            <<"t/foo${username}boo">>,
            emqx_authz_rule:compile({allow, {username, "test"}, publish, ["t/foo${username}boo"]})
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => false},
            <<"t/footestboo">>,
            emqx_authz_rule:compile({allow, {username, "test"}, publish, ["t/foo${username}boo"]})
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 1, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {publish, [{retain, all}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {publish, [{retain, all}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 1, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {publish, [{qos, 1}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 0, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {publish, [{qos, 1}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 1, retain => false},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {publish, [{qos, 1}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {subscribe, []}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {subscribe, []}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 1},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {subscribe, [{qos, 1}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {subscribe, [{qos, 1}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 0},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 1, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 2, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile(
                {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
            )
        )
    ),

    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 2, retain => true},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, all, publish, ["#"]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, all, publish, ["#"]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{username => undefined, peerhost => undefined}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, {username, "user"}, all, ["#"]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{username => undefined, peerhost => undefined}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, {ipaddr, "127.0.0.1"}, all, ["#"]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{username => undefined, peerhost => undefined}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, {ipaddrs, []}, all, ["#"]})
        )
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:match(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => subscribe, qos => 2},
            <<"topic/test">>,
            emqx_authz_rule:compile({allow, {clientid, {re, "^test"}}, all, ["#"]})
        )
    ),

    ok.

t_invalid_rule(_) ->
    ?assertThrow(
        {invalid_authorization_permission, _},
        emqx_authz_rule:compile({allawww, all, all, ["topic/test"]})
    ),

    ?assertThrow(
        {invalid_authorization_rule, _},
        emqx_authz_rule:compile(ooops)
    ),

    ?assertThrow(
        {invalid_authorization_qos, _},
        emqx_authz_rule:compile({allow, {username, "test"}, {publish, [{qos, 3}]}, ["topic/test"]})
    ),

    ?assertThrow(
        {invalid_authorization_retain, _},
        emqx_authz_rule:compile(
            {allow, {username, "test"}, {publish, [{retain, 'FALSE'}]}, ["topic/test"]}
        )
    ),

    ?assertThrow(
        {invalid_authorization_action, _},
        emqx_authz_rule:compile({allow, all, unsubscribe, ["topic/test"]})
    ),

    ?assertThrow(
        {invalid_who, _},
        emqx_authz_rule:compile({allow, who, all, ["topic/test"]})
    ).

t_matches(_) ->
    ?assertEqual(
        {matched, allow},
        emqx_authz_rule:matches(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 2, retain => true},
            <<"topic/test">>,
            [
                emqx_authz_rule:compile(
                    {allow, {username, "test"}, {subscribe, [{qos, 1}]}, ["topic/test"]}
                ),
                emqx_authz_rule:compile(
                    {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
                )
            ]
        )
    ),

    Rule = emqx_authz_rule:compile(
        {allow, {username, "test"}, {all, [{qos, 2}, {retain, true}]}, ["topic/test"]}
    ),

    ?assertEqual(
        nomatch,
        emqx_authz_rule:matches(
            client_info(#{clientid => <<"fake">>}),
            #{action_type => publish, qos => 1, retain => true},
            <<"topic/test">>,
            [Rule, Rule, Rule]
        )
    ).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

client_info() ->
    ?CLIENT_INFO_BASE.

client_info(Overrides) ->
    maps:merge(?CLIENT_INFO_BASE, Overrides).
