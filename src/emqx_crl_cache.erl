%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% @doc EMQX CRL cache.
%%--------------------------------------------------------------------

-module(emqx_crl_cache).

%% API
-export([ start_link/0
        , start_link/1
        , refresh/1
        , evict/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        ]).

%% internal exports
-export([http_get/2]).

-behaviour(gen_server).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(LOG(Level, Format, Args),
        logger:log(Level, "[~p] " ++ Format, [?MODULE | Args])).
-define(HTTP_TIMEOUT, timer:seconds(10)).
-define(RETRY_TIMEOUT, 5_000).

-record(state,
        { refresh_timers   = #{}               :: #{binary() => timer:tref()}
        , refresh_interval = timer:minutes(15) :: timer:time()
        }).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    URLs = emqx:get_env(crl_cache_urls, []),
    RefreshIntervalMS = emqx:get_env(crl_cache_refresh_interval,
                                     timer:minutes(15)),
    start_link(#{urls => URLs, refresh_interval => RefreshIntervalMS}).

start_link(Opts = #{urls := _, refresh_interval := _}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

refresh(URL) ->
    gen_server:call(?MODULE, {refresh, URL}, ?HTTP_TIMEOUT + 2_000).

evict(URL) ->
    gen_server:cast(?MODULE, {evict, URL}).

%%--------------------------------------------------------------------
%% gen_server behaviour
%%--------------------------------------------------------------------

init(#{urls := URLs, refresh_interval := RefreshIntervalMS}) ->
    State = lists:foldl(fun(URL, Acc) -> ensure_timer(URL, Acc, 0) end,
                        #state{refresh_interval = RefreshIntervalMS},
                        URLs),
    {ok, State}.

handle_call({refresh, URL}, _From, State0) ->
    case do_http_fetch_and_cache(URL) of
        {error, Error} ->
            ?LOG(error, "failed to fetch crl response for ~p; error: ~p",
                 [URL, Error]),
            {reply, error, ensure_timer(URL, State0, ?RETRY_TIMEOUT)};
        {ok, CRLs} ->
            ?LOG(debug, "fetched crl response for ~p", [URL]),
            {reply, {ok, CRLs}, ensure_timer(URL, State0)}
    end;
handle_call(Call, _From, State) ->
    {reply, {error, {bad_call, Call}}, State}.

handle_cast({evict, URL}, State0 = #state{refresh_timers = RefreshTimers0}) ->
    ssl_crl_cache:delete(URL),
    MTimer = maps:get(URL, RefreshTimers0, undefined),
    emqx_misc:cancel_timer(MTimer),
    RefreshTimers = maps:without([URL], RefreshTimers0),
    State = State0#state{refresh_timers = RefreshTimers},
    ?tp(crl_cache_evict,
        #{ url => URL
         }),
    {noreply, State};
handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({timeout, TRef, {refresh, URL}},
            State = #state{refresh_timers = RefreshTimers}) ->
    case maps:get(URL, RefreshTimers, undefined) of
        TRef ->
            ?tp(crl_refresh_timer, #{url => URL}),
            ?LOG(debug, "refreshing crl response for ~p", [URL]),
            case do_http_fetch_and_cache(URL) of
                {error, Error} ->
                    ?LOG(error, "failed to fetch crl response for ~p; error: ~p",
                         [URL, Error]),
                    {noreply, ensure_timer(URL, State, ?RETRY_TIMEOUT)};
                {ok, _CRLs} ->
                    ?LOG(debug, "fetched crl response for ~p", [URL]),
                    {noreply, ensure_timer(URL, State)}
            end;
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% internal functions
%%--------------------------------------------------------------------

http_get(URL, HTTPTimeout) ->
    httpc:request(
      get,
      {URL,
       [{"connection", "close"}]},
      [{timeout, HTTPTimeout}],
      [{body_format, binary}]
     ).

do_http_fetch_and_cache(URL) ->
    %% FIXME
    Resp = ?MODULE:http_get(URL, ?HTTP_TIMEOUT),
    case Resp of
        {ok, {{_, 200, _}, _, Body}} ->
            case parse_crls(Body) of
                error ->
                    {error, invalid_crl};
                CRLs ->
                    ssl_crl_cache:insert(URL, {der, CRLs}),
                    ?tp(crl_cache_insert, #{url => URL}),
                    {ok, CRLs}
            end;
        {ok, {{_, Code, _}, _, Body}} ->
            {error, {bad_response, #{code => Code, body => Body}}};
        {error, Error} ->
            {error, {http_error, Error}}
    end.

parse_crls(Bin) ->
    try
        [CRL || {'CertificateList', CRL, not_encrypted} <- public_key:pem_decode(Bin)]
    catch
        _:_ ->
            error
    end.

ensure_timer(URL, State = #state{refresh_interval = Timeout}) ->
    ensure_timer(URL, State, Timeout).

ensure_timer(URL, State = #state{refresh_timers = RefreshTimers0}, Timeout) ->
    MTimer = maps:get(URL, RefreshTimers0, undefined),
    emqx_misc:cancel_timer(MTimer),
    RefreshTimers = RefreshTimers0#{URL => emqx_misc:start_timer(
                                             Timeout,
                                             {refresh, URL})},
    State#state{refresh_timers = RefreshTimers}.
