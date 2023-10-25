%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authz).

-behaviour(emqx_config_handler).
-behaviour(emqx_config_backup).

-dialyzer({nowarn_function, [authz_module/1]}).

-include("emqx_authz.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-export([
    register_source/2,
    unregister_source/1,
    register_metrics/0,
    init/0,
    deinit/0,
    merge_defaults/1,
    lookup/0,
    lookup/1,
    move/2,
    update/2,
    merge/1,
    merge_local/2,
    authorize/5,
    authorize_deny/4,
    %% for telemetry information
    get_enabled_authzs/0
]).

-export([
    feature_available/1,
    set_feature_available/2
]).

-export([post_config_update/5, pre_config_update/3]).

-export([
    maybe_read_source_files/1,
    maybe_read_source_files_safe/1
]).

%% Data backup
-export([
    import_config/1,
    maybe_read_files/1,
    maybe_write_files/1
]).

-type default_result() :: allow | deny.

-type authz_result_value() :: #{result := allow | deny, from => _}.
-type authz_result() :: {stop, authz_result_value()} | {ok, authz_result_value()} | ignore.

-type source() :: emqx_authz_source:source().
-type sources() :: [source()].

-define(METRIC_SUPERUSER, 'authorization.superuser').
-define(METRIC_ALLOW, 'authorization.matched.allow').
-define(METRIC_DENY, 'authorization.matched.deny').
-define(METRIC_NOMATCH, 'authorization.nomatch').

-define(METRICS, [?METRIC_SUPERUSER, ?METRIC_ALLOW, ?METRIC_DENY, ?METRIC_NOMATCH]).

-spec register_metrics() -> ok.
register_metrics() ->
    lists:foreach(fun emqx_metrics:ensure/1, ?METRICS).

init() ->
    ok = register_metrics(),
    emqx_conf:add_handler(?CONF_KEY_PATH, ?MODULE),
    emqx_conf:add_handler(?ROOT_KEY, ?MODULE),
    ok = emqx_hooks:put('client.authorize', {?MODULE, authorize_deny, []}, ?HP_AUTHZ),
    ok = register_builtin_sources(),
    ok.

register_source(Type, Module) ->
    ok = emqx_authz_source_registry:register(Type, Module),
    install_sources(not is_hook_installed() andalso are_all_providers_registered()).

unregister_source(Type) ->
    ok = emqx_authz_source_registry:unregister(Type).

is_hook_installed() ->
    lists:any(
        fun(Callback) ->
            case emqx_hooks:callback_action(Callback) of
                {?MODULE, authorize, _} -> true;
                _ -> false
            end
        end,
        emqx_hooks:lookup('client.authorize')
    ).

are_all_providers_registered() ->
    try
        _ = lists:foreach(
            fun(Type) ->
                _ = emqx_authz_source_registry:get(Type)
            end,
            configured_types()
        ),
        true
    catch
        {unknown_authz_source_type, _Type} ->
            false
    end.

register_builtin_sources() ->
    lists:foreach(
        fun({Type, Module}) ->
            register_source(Type, Module)
        end,
        ?BUILTIN_SOURCES
    ).

configured_types() ->
    lists:map(
        fun(#{type := Type}) -> Type end,
        emqx_conf:get(?CONF_KEY_PATH, [])
    ).

install_sources(true) ->
    ok = init_metrics(client_info_source()),
    Sources = emqx_conf:get(?CONF_KEY_PATH, []),
    ok = check_dup_types(Sources),
    NSources = create_sources(Sources),
    ok = emqx_hooks:put('client.authorize', {?MODULE, authorize, [NSources]}, ?HP_AUTHZ),
    ok = emqx_hooks:del('client.authorize', {?MODULE, authorize_deny});
install_sources(false) ->
    ok.

deinit() ->
    ok = emqx_hooks:del('client.authorize', {?MODULE, authorize}),
    ok = emqx_hooks:del('client.authorize', {?MODULE, authorize_deny}),
    emqx_conf:remove_handler(?CONF_KEY_PATH),
    emqx_conf:remove_handler(?ROOT_KEY),
    emqx_authz_utils:cleanup_resources().

lookup() ->
    {_M, _F, [A]} = find_action_in_hooks(),
    A.

lookup(Type) ->
    {Source, _Front, _Rear} = take(Type),
    Source.

merge(NewConf) ->
    emqx_authz_utils:update_config(?ROOT_KEY, {?CMD_MERGE, NewConf}).

merge_local(NewConf, Opts) ->
    emqx:update_config(?ROOT_KEY, {?CMD_MERGE, NewConf}, Opts).

move(Type, ?CMD_MOVE_BEFORE(Before)) ->
    emqx_authz_utils:update_config(
        ?CONF_KEY_PATH, {?CMD_MOVE, type(Type), ?CMD_MOVE_BEFORE(type(Before))}
    );
move(Type, ?CMD_MOVE_AFTER(After)) ->
    emqx_authz_utils:update_config(
        ?CONF_KEY_PATH, {?CMD_MOVE, type(Type), ?CMD_MOVE_AFTER(type(After))}
    );
move(Type, Position) ->
    emqx_authz_utils:update_config(
        ?CONF_KEY_PATH, {?CMD_MOVE, type(Type), Position}
    ).

update({?CMD_REPLACE, Type}, Sources) ->
    emqx_authz_utils:update_config(?CONF_KEY_PATH, {{?CMD_REPLACE, type(Type)}, Sources});
update({?CMD_DELETE, Type}, Sources) ->
    emqx_authz_utils:update_config(?CONF_KEY_PATH, {{?CMD_DELETE, type(Type)}, Sources});
update(Cmd, Sources) ->
    emqx_authz_utils:update_config(?CONF_KEY_PATH, {Cmd, Sources}).

pre_config_update(Path, Cmd, Sources) ->
    try do_pre_config_update(Path, Cmd, Sources) of
        {error, Reason} -> {error, Reason};
        NSources -> {ok, NSources}
    catch
        throw:Reason ->
            ?SLOG(info, #{
                msg => "error_in_pre_config_update",
                reason => Reason
            }),
            {error, Reason};
        Error:Reason:Stack ->
            ?SLOG(warning, #{
                msg => "error_in_pre_config_update",
                exception => Error,
                reason => Reason,
                stacktrace => Stack
            }),
            {error, Reason}
    end.

do_pre_config_update(?CONF_KEY_PATH, Cmd, Sources) ->
    do_pre_config_update(Cmd, Sources);
do_pre_config_update(?ROOT_KEY, {?CMD_MERGE, NewConf}, OldConf) ->
    do_pre_config_merge(NewConf, OldConf);
do_pre_config_update(?ROOT_KEY, NewConf, OldConf) ->
    do_pre_config_replace(NewConf, OldConf).

do_pre_config_merge(NewConf, OldConf) ->
    MergeConf = emqx_utils_maps:deep_merge(OldConf, NewConf),
    NewSources = merge_sources(OldConf, NewConf),
    do_pre_config_replace(MergeConf#{<<"sources">> => NewSources}, OldConf).

%% override the entire config when updating the root key
%% emqx_conf:update(?ROOT_KEY, Conf);
do_pre_config_replace(Conf, Conf) ->
    Conf;
do_pre_config_replace(NewConf, OldConf) ->
    NewSources = get_sources(NewConf),
    OldSources = get_sources(OldConf),
    ReplaceSources = do_pre_config_update({?CMD_REPLACE, NewSources}, OldSources),
    NewConf#{<<"sources">> => ReplaceSources}.

do_pre_config_update({?CMD_MOVE, _, _} = Cmd, Sources) ->
    do_move(Cmd, Sources);
do_pre_config_update({?CMD_PREPEND, Source}, Sources) ->
    NSource = maybe_write_source_files(Source),
    NSources = [NSource] ++ Sources,
    ok = check_dup_types(NSources),
    NSources;
do_pre_config_update({?CMD_APPEND, Source}, Sources) ->
    NSource = maybe_write_source_files(Source),
    NSources = Sources ++ [NSource],
    ok = check_dup_types(NSources),
    NSources;
do_pre_config_update({{?CMD_REPLACE, Type}, Source}, Sources) ->
    NSource = maybe_write_source_files(Source),
    {_Old, Front, Rear} = take(Type, Sources),
    NSources = Front ++ [NSource | Rear],
    ok = check_dup_types(NSources),
    NSources;
do_pre_config_update({{?CMD_DELETE, Type}, _Source}, Sources) ->
    {_Old, Front, Rear} = take(Type, Sources),
    NSources = Front ++ Rear,
    NSources;
do_pre_config_update({?CMD_REPLACE, Sources}, _OldSources) ->
    %% overwrite the entire config!
    NSources = lists:map(fun maybe_write_source_files/1, Sources),
    ok = check_dup_types(NSources),
    NSources;
do_pre_config_update({Op, Source}, Sources) ->
    throw({bad_request, #{op => Op, source => Source, sources => Sources}}).

post_config_update(_, _, undefined, _OldSource, _AppEnvs) ->
    ok;
post_config_update(Path, Cmd, NewSources, _OldSource, _AppEnvs) ->
    Actions = do_post_config_update(Path, Cmd, NewSources),
    ok = update_authz_chain(Actions),
    ok = emqx_authz_cache:drain_cache().

do_post_config_update(?CONF_KEY_PATH, {?CMD_MOVE, _Type, _Where} = Cmd, _Sources) ->
    do_move(Cmd, lookup());
do_post_config_update(?CONF_KEY_PATH, {?CMD_PREPEND, RawNewSource}, Sources) ->
    TypeName = type(RawNewSource),
    NewSources = create_sources([get_source_by_type(TypeName, Sources)]),
    NewSources ++ lookup();
do_post_config_update(?CONF_KEY_PATH, {?CMD_APPEND, RawNewSource}, Sources) ->
    NewSources = create_sources([get_source_by_type(type(RawNewSource), Sources)]),
    lookup() ++ NewSources;
do_post_config_update(?CONF_KEY_PATH, {{?CMD_REPLACE, Type}, RawNewSource}, Sources) ->
    OldSources = lookup(),
    {OldSource, Front, Rear} = take(Type, OldSources),
    NewSource = get_source_by_type(type(RawNewSource), Sources),
    InitedSources = update_source(type(RawNewSource), OldSource, NewSource),
    Front ++ [InitedSources] ++ Rear;
do_post_config_update(?CONF_KEY_PATH, {{?CMD_DELETE, Type}, _RawNewSource}, _Sources) ->
    OldInitedSources = lookup(),
    {OldSource, Front, Rear} = take(Type, OldInitedSources),
    ok = ensure_deleted(OldSource, #{clear_metric => true}),
    Front ++ Rear;
do_post_config_update(?CONF_KEY_PATH, {?CMD_REPLACE, _RawNewSources}, Sources) ->
    overwrite_entire_sources(Sources);
do_post_config_update(?ROOT_KEY, Conf, Conf) ->
    #{sources := Sources} = Conf,
    Sources;
do_post_config_update(?ROOT_KEY, _Conf, NewConf) ->
    #{sources := NewSources} = NewConf,
    overwrite_entire_sources(NewSources).

overwrite_entire_sources(Sources) ->
    PrevSources = lookup(),
    NewSourcesTypes = lists:map(fun type/1, Sources),
    EnsureDelete = fun(S) ->
        TypeName = type(S),
        Opts =
            case lists:member(TypeName, NewSourcesTypes) of
                true -> #{clear_metric => false};
                false -> #{clear_metric => true}
            end,
        ensure_deleted(S, Opts)
    end,
    lists:foreach(EnsureDelete, PrevSources),
    create_sources(Sources).

%% @doc do source move
do_move({?CMD_MOVE, Type, ?CMD_MOVE_FRONT}, Sources) ->
    {Source, Front, Rear} = take(Type, Sources),
    [Source | Front] ++ Rear;
do_move({?CMD_MOVE, Type, ?CMD_MOVE_REAR}, Sources) ->
    {Source, Front, Rear} = take(Type, Sources),
    Front ++ Rear ++ [Source];
do_move({?CMD_MOVE, Type, ?CMD_MOVE_BEFORE(Before)}, Sources) ->
    {S1, Front1, Rear1} = take(Type, Sources),
    {S2, Front2, Rear2} = take(Before, Front1 ++ Rear1),
    Front2 ++ [S1, S2] ++ Rear2;
do_move({?CMD_MOVE, Type, ?CMD_MOVE_AFTER(After)}, Sources) ->
    {S1, Front1, Rear1} = take(Type, Sources),
    {S2, Front2, Rear2} = take(After, Front1 ++ Rear1),
    Front2 ++ [S2, S1] ++ Rear2.

ensure_deleted(#{enable := false}, _) ->
    ok;
ensure_deleted(Source, #{clear_metric := ClearMetric}) ->
    TypeName = type(Source),
    ensure_resource_deleted(Source),
    ClearMetric andalso emqx_metrics_worker:clear_metrics(authz_metrics, TypeName).

ensure_resource_deleted(#{type := Type} = Source) ->
    Module = authz_module(Type),
    Module:destroy(Source).

check_dup_types(Sources) ->
    check_dup_types(Sources, []).

check_dup_types([], _Checked) ->
    ok;
check_dup_types([Source | Sources], Checked) ->
    %% the input might be raw or type-checked result, so lookup both 'type' and <<"type">>
    %% TODO: check: really?
    Type =
        case maps:get(<<"type">>, Source, maps:get(type, Source, undefined)) of
            undefined ->
                %% this should never happen if the value is type checked by honcon schema
                throw({bad_source_input, Source});
            Type0 ->
                type(Type0)
        end,
    case lists:member(Type, Checked) of
        true ->
            %% we have made it clear not to support more than one authz instance for each type
            throw({duplicated_authz_source_type, Type});
        false ->
            check_dup_types(Sources, [Type | Checked])
    end.

create_sources(Sources) ->
    {_Enabled, Disabled} = lists:partition(fun(#{enable := Enable}) -> Enable end, Sources),
    case Disabled =/= [] of
        true -> ?SLOG(info, #{msg => "disabled_sources_ignored", sources => Disabled});
        false -> ok
    end,
    ok = lists:foreach(fun init_metrics/1, Sources),
    lists:map(fun create_source/1, Sources).

create_source(#{type := Type} = Source) ->
    Module = authz_module(Type),
    Module:create(Source).

update_source(Type, OldSource, NewSource) ->
    Module = authz_module(Type),
    Module:update(maps:merge(OldSource, NewSource)).

init_metrics(Source) ->
    TypeName = type(Source),
    case emqx_metrics_worker:has_metrics(authz_metrics, TypeName) of
        %% Don't reset the metrics if it already exists
        true ->
            ok;
        false ->
            emqx_metrics_worker:create_metrics(
                authz_metrics,
                TypeName,
                [total, allow, deny, nomatch],
                [total]
            )
    end.

%%------------------------------------------------------------------------------
%% AuthZ callbacks
%%------------------------------------------------------------------------------

-spec authorize_deny(
    emqx_types:clientinfo(),
    emqx_types:pubsub(),
    emqx_types:topic(),
    default_result()
) ->
    {stop, #{result => deny, from => ?MODULE}}.
authorize_deny(
    #{
        username := Username,
        peerhost := IpAddress
    } = _Client,
    _PubSub,
    Topic,
    _DefaultResult
) ->
    emqx_metrics:inc(?METRIC_DENY),
    ?SLOG(warning, #{
        msg => "authorization_not_initialized",
        username => Username,
        ipaddr => IpAddress,
        topic => Topic,
        source => ?MODULE
    }),
    {stop, #{result => deny, from => ?MODULE}}.

%% @doc Check AuthZ
-spec authorize(
    emqx_types:clientinfo(),
    emqx_types:pubsub(),
    emqx_types:topic(),
    default_result(),
    sources()
) ->
    authz_result().
authorize(
    #{
        username := Username,
        peerhost := IpAddress
    } = Client,
    PubSub,
    Topic,
    DefaultResult,
    Sources
) ->
    case maps:get(is_superuser, Client, false) of
        true ->
            log_allowed(#{
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                is_superuser => true
            }),
            emqx_metrics:inc(?METRIC_SUPERUSER),
            {stop, #{result => allow, from => superuser}};
        false ->
            authorize_non_superuser(Client, PubSub, Topic, DefaultResult, Sources)
    end.

authorize_non_superuser(
    #{
        username := Username,
        peerhost := IpAddress
    } = Client,
    PubSub,
    Topic,
    _DefaultResult,
    Sources
) ->
    case do_authorize(Client, PubSub, Topic, sources_with_defaults(Sources)) of
        {{matched, allow}, AuthzSource} ->
            log_allowed(#{
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                source => AuthzSource
            }),
            emqx_metrics_worker:inc(authz_metrics, AuthzSource, allow),
            emqx_metrics:inc(?METRIC_ALLOW),
            {stop, #{result => allow, from => AuthzSource}};
        {{matched, deny}, AuthzSource} ->
            ?SLOG(warning, #{
                msg => "authorization_permission_denied",
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                source => AuthzSource
            }),
            emqx_metrics_worker:inc(authz_metrics, AuthzSource, deny),
            emqx_metrics:inc(?METRIC_DENY),
            {stop, #{result => deny, from => AuthzSource}};
        nomatch ->
            ?tp(authz_non_superuser, #{result => nomatch}),
            ?SLOG(info, #{
                msg => "authorization_failed_nomatch",
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                reason => "no-match rule"
            }),
            emqx_metrics:inc(?METRIC_NOMATCH),
            ignore
    end.

log_allowed(Meta) ->
    ?SLOG(info, Meta#{msg => "authorization_permission_allowed"}).

do_authorize(_Client, _PubSub, _Topic, []) ->
    nomatch;
do_authorize(Client, PubSub, Topic, [#{enable := false} | Rest]) ->
    do_authorize(Client, PubSub, Topic, Rest);
do_authorize(
    #{
        username := Username,
        peerhost := IpAddress
    } = Client,
    PubSub,
    Topic,
    [Connector = #{type := Type} | Tail]
) ->
    Module = authz_module(Type),
    emqx_metrics_worker:inc(authz_metrics, Type, total),
    try Module:authorize(Client, PubSub, Topic, Connector) of
        nomatch ->
            emqx_metrics_worker:inc(authz_metrics, Type, nomatch),
            ?TRACE("AUTHZ", "authorization_module_nomatch", #{
                module => Module,
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                pub_sub => PubSub
            }),
            do_authorize(Client, PubSub, Topic, Tail);
        %% {matched, allow | deny | ignore}
        {matched, ignore} ->
            ?TRACE("AUTHZ", "authorization_module_match_ignore", #{
                module => Module,
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                pub_sub => PubSub
            }),
            do_authorize(Client, PubSub, Topic, Tail);
        ignore ->
            ?TRACE("AUTHZ", "authorization_module_ignore", #{
                module => Module,
                username => Username,
                ipaddr => IpAddress,
                topic => Topic,
                pub_sub => PubSub
            }),
            do_authorize(Client, PubSub, Topic, Tail);
        %% {matched, allow | deny}
        Matched ->
            {Matched, Type}
    catch
        Class:Reason:Stacktrace ->
            emqx_metrics_worker:inc(authz_metrics, Type, nomatch),
            ?SLOG(warning, #{
                msg => "unexpected_error_in_authorize",
                exception => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                authorize_type => Type
            }),
            do_authorize(Client, PubSub, Topic, Tail)
    end.

get_enabled_authzs() ->
    lists:usort([Type || #{type := Type, enable := true} <- lookup()]).

%%------------------------------------------------------------------------------
%% Data backup
%%------------------------------------------------------------------------------

import_config(#{?CONF_NS_BINARY := AuthzConf}) ->
    Sources = get_sources(AuthzConf),
    OldSources = emqx:get_raw_config(?CONF_KEY_PATH, [emqx_authz_schema:default_authz()]),
    MergedSources = emqx_utils:merge_lists(OldSources, Sources, fun type/1),
    MergedAuthzConf = AuthzConf#{<<"sources">> => MergedSources},
    case emqx_conf:update([?CONF_NS_ATOM], MergedAuthzConf, #{override_to => cluster}) of
        {ok, #{raw_config := #{<<"sources">> := NewSources}}} ->
            {ok, #{
                root_key => ?CONF_NS_ATOM,
                changed => changed_paths(OldSources, NewSources)
            }};
        Error ->
            {error, #{root_key => ?CONF_NS_ATOM, reason => Error}}
    end;
import_config(_RawConf) ->
    {ok, #{root_key => ?CONF_NS_ATOM, changed => []}}.

changed_paths(OldSources, NewSources) ->
    Changed = maps:get(changed, emqx_utils:diff_lists(NewSources, OldSources, fun type/1)),
    [?CONF_KEY_PATH ++ [type(OldSource)] || {OldSource, _} <- Changed].

maybe_read_files(RawConf) ->
    maybe_convert_sources(RawConf, fun maybe_read_source_files/1).

maybe_write_files(RawConf) ->
    maybe_convert_sources(RawConf, fun maybe_write_source_files/1).

maybe_convert_sources(
    #{?CONF_NS_BINARY := #{<<"sources">> := Sources} = AuthRawConf} = RawConf, Fun
) ->
    Sources1 = lists:map(Fun, Sources),
    RawConf#{?CONF_NS_BINARY => AuthRawConf#{<<"sources">> => Sources1}};
maybe_convert_sources(RawConf, _Fun) ->
    RawConf.

%%------------------------------------------------------------------------------
%% Extended Features
%%------------------------------------------------------------------------------

-define(DEFAULT_RICH_ACTIONS, true).

-define(FEATURE_KEY(_NAME_), {?MODULE, _NAME_}).

feature_available(rich_actions) ->
    persistent_term:get(?FEATURE_KEY(rich_actions), ?DEFAULT_RICH_ACTIONS).

set_feature_available(Feature, Enable) when is_boolean(Enable) ->
    persistent_term:put(?FEATURE_KEY(Feature), Enable).

%%------------------------------------------------------------------------------
%% Internal function
%%------------------------------------------------------------------------------

client_info_source() ->
    emqx_authz_client_info:create(
        #{type => client_info, enable => true}
    ).

sources_with_defaults(Sources) ->
    [client_info_source() | Sources].

take(Type) -> take(Type, lookup()).

%% Take the source of give type, the sources list is split into two parts
%% front part and rear part.
take(Type, Sources) ->
    Expect = type(Type),
    case lists:splitwith(fun(T) -> type(T) =/= Expect end, Sources) of
        {_Front, []} ->
            throw({not_found_source, Type});
        {Front, [Found | Rear]} ->
            {Found, Front, Rear}
    end.

find_action_in_hooks() ->
    Actions = lists:filtermap(
        fun(Callback) ->
            case emqx_hooks:callback_action(Callback) of
                {?MODULE, authorize, _} = Action -> {true, Action};
                _ -> false
            end
        end,
        emqx_hooks:lookup('client.authorize')
    ),
    case Actions of
        [] ->
            ?SLOG(error, #{
                msg => "authz_not_initialized",
                configured_types => configured_types(),
                registered_types => emqx_authz_source_registry:get()
            }),
            error(authz_not_initialized);
        [Action] ->
            Action
    end.

authz_module(Type) ->
    emqx_authz_source_registry:module(Type).

type(#{type := Type}) ->
    type(Type);
type(#{<<"type">> := Type}) ->
    type(Type);
type(Type) when is_atom(Type) orelse is_binary(Type) ->
    emqx_authz_source_registry:get(Type).

merge_defaults(Source) ->
    Type = type(Source),
    Mod = authz_module(Type),
    try
        Mod:merge_defaults(Source)
    catch
        error:undef ->
            Source
    end.

maybe_write_source_files(Source) ->
    Module = authz_module(type(Source)),
    case erlang:function_exported(Module, write_files, 1) of
        true ->
            Module:write_files(Source);
        false ->
            maybe_write_certs(Source)
    end.

maybe_read_source_files(Source) ->
    Module = authz_module(type(Source)),
    case erlang:function_exported(Module, read_files, 1) of
        true ->
            Module:read_files(Source);
        false ->
            Source
    end.

maybe_read_source_files_safe(Source0) ->
    try maybe_read_source_files(Source0) of
        Source1 ->
            {ok, Source1}
    catch
        Error:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "error_when_reading_source_files",
                exception => Error,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

maybe_write_certs(#{<<"type">> := Type, <<"ssl">> := SSL = #{}} = Source) ->
    case emqx_tls_lib:ensure_ssl_files(ssl_file_path(Type), SSL) of
        {ok, NSSL} ->
            Source#{<<"ssl">> => NSSL};
        {error, Reason} ->
            ?SLOG(error, Reason#{msg => "bad_ssl_config"}),
            throw({bad_ssl_config, Reason})
    end;
maybe_write_certs(#{} = Source) ->
    Source.

ssl_file_path(Type) ->
    filename:join(["authz", Type]).

get_source_by_type(Type, Sources) ->
    {Source, _Front, _Rear} = take(Type, Sources),
    Source.

%% @doc put hook with (maybe) initialized new source and old sources
update_authz_chain(Actions) ->
    emqx_hooks:put('client.authorize', {?MODULE, authorize, [Actions]}, ?HP_AUTHZ).

merge_sources(OriginConf, NewConf) ->
    {OriginSource, NewSources} =
        lists:foldl(
            fun(Old = #{<<"type">> := Type}, {OriginAcc, NewAcc}) ->
                case type_take(Type, NewAcc) of
                    not_found ->
                        {[Old | OriginAcc], NewAcc};
                    {New, NewAcc1} ->
                        MergeSource = emqx_utils_maps:deep_merge(Old, New),
                        {[MergeSource | OriginAcc], NewAcc1}
                end
            end,
            {[], get_sources(NewConf)},
            get_sources(OriginConf)
        ),
    lists:reverse(OriginSource) ++ NewSources.

get_sources(Conf) ->
    Default = [emqx_authz_schema:default_authz()],
    maps:get(<<"sources">>, Conf, Default).

type_take(Type, Sources) ->
    try take(Type, Sources) of
        {Found, Front, Rear} -> {Found, Front ++ Rear}
    catch
        throw:{not_found_source, Type} -> not_found
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(nowarn_export_all).
-compile(export_all).

merge_sources_test() ->
    ok = emqx_authz_source_registry:create(),
    ok = lists:foreach(
        fun(Type) ->
            ok = emqx_authz_source_registry:register(Type, ?MODULE)
        end,
        [file, http, mysql, mongodb, redis, postgresql]
    ),
    Default = [emqx_authz_schema:default_authz()],
    Http = #{<<"type">> => <<"http">>, <<"enable">> => true},
    Mysql = #{<<"type">> => <<"mysql">>, <<"enable">> => true},
    Mongo = #{<<"type">> => <<"mongodb">>, <<"enable">> => true},
    Redis = #{<<"type">> => <<"redis">>, <<"enable">> => true},
    Postgresql = #{<<"type">> => <<"postgresql">>, <<"enable">> => true},
    HttpDisable = Http#{<<"enable">> => false},
    MysqlDisable = Mysql#{<<"enable">> => false},
    MongoDisable = Mongo#{<<"enable">> => false},

    %% has default source
    ?assertEqual(Default, merge_sources(#{}, #{})),
    ?assertEqual([], merge_sources(#{<<"sources">> => []}, #{<<"sources">> => []})),
    ?assertEqual(Default, merge_sources(#{}, #{<<"sources">> => []})),

    %% add
    ?assertEqual(
        [Http, Mysql, Mongo, Redis, Postgresql],
        merge_sources(
            #{<<"sources">> => [Http, Mysql]},
            #{<<"sources">> => [Mongo, Redis, Postgresql]}
        )
    ),
    %% replace
    ?assertEqual(
        [HttpDisable, MysqlDisable],
        merge_sources(
            #{<<"sources">> => [Http, Mysql]},
            #{<<"sources">> => [HttpDisable, MysqlDisable]}
        )
    ),
    %% add + replace + change position
    ?assertEqual(
        [HttpDisable, Mysql, MongoDisable, Redis],
        merge_sources(
            #{<<"sources">> => [Http, Mysql, Mongo]},
            #{<<"sources">> => [MongoDisable, HttpDisable, Redis]}
        )
    ),
    ok.

-endif.
