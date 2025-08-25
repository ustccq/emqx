%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn_jwks_client).

-behaviour(gen_server).

-include_lib("emqx/include/logger.hrl").
-include_lib("jose/include/jose_jwk.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-export([
    start_link/1,
    stop/1
]).

-export([
    get_jwks/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

stop(Pid) ->
    gen_server:stop(Pid).

get_jwks(Pid) ->
    gen_server:call(Pid, get_cached_jwks, 5000).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Opts]) ->
    State = handle_options(Opts),
    {ok, refresh_jwks(State)}.

handle_call(get_cached_jwks, _From, #{jwks := JWKS} = State) ->
    {reply, {ok, JWKS}, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh_jwks, State) ->
    State0 = cancel_http_request(State),
    State1 = refresh_jwks(State0),
    ?tp(debug, refresh_jwks_by_timer, #{}),
    {noreply, State1};
handle_info(
    {http, {RequestID, Result}},
    #{request_id := RequestID, endpoint := Endpoint} = State0
) ->
    ?tp(debug, jwks_endpoint_response, #{
        request_id => RequestID, response => emqx_utils:redact(Result)
    }),
    State1 = State0#{request_id := undefined},
    NewState =
        case Result of
            {error, Reason} ->
                ?SLOG(warning, #{
                    msg => "failed_to_request_jwks_endpoint",
                    endpoint => Endpoint,
                    reason => Reason
                }),
                State1;
            {StatusLine, Headers, Body} ->
                try
                    JWK = jose_jwk:from(emqx_utils_json:decode(Body)),
                    {_, JWKS} = JWK#jose_jwk.keys,
                    State1#{jwks := JWKS}
                catch
                    _:_ ->
                        ?SLOG(warning, #{
                            msg => "invalid_jwks_returned",
                            endpoint => Endpoint,
                            status => StatusLine,
                            headers => Headers,
                            body => Body
                        }),
                        State1
                end
        end,
    {noreply, NewState};
handle_info({http, {_, _}}, State) ->
    %% ignore
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

handle_options(#{
    endpoint := Endpoint,
    headers := Headers,
    refresh_interval := RefreshInterval0,
    ssl := SSLOpts
}) ->
    #{
        endpoint => Endpoint,
        headers => to_httpc_headers(Headers),
        refresh_interval => limit_refresh_interval(RefreshInterval0),
        ssl_opts => emqx_tls_lib:to_client_opts(SSLOpts),
        jwks => [],
        request_id => undefined
    }.

refresh_jwks(
    #{
        endpoint := Endpoint,
        headers := Headers,
        ssl_opts := SSLOpts
    } = State
) ->
    HTTPOpts = [
        {timeout, 5000},
        {connect_timeout, 5000},
        {ssl, SSLOpts}
    ],
    NState =
        case
            httpc:request(
                get,
                {Endpoint, Headers},
                HTTPOpts,
                [{body_format, binary}, {sync, false}, {receiver, self()}]
            )
        of
            {error, Reason} ->
                ?tp(warning, jwks_endpoint_request_fail, #{
                    endpoint => Endpoint,
                    http_opts => HTTPOpts,
                    reason => Reason
                }),
                State;
            {ok, RequestID} ->
                ?tp(debug, jwks_endpoint_request_ok, #{request_id => RequestID}),
                State#{request_id := RequestID}
        end,
    ensure_expiry_timer(NState).

ensure_expiry_timer(State = #{refresh_interval := Interval}) ->
    State#{refresh_timer => erlang:send_after(timer:seconds(Interval), self(), refresh_jwks)}.

limit_refresh_interval(Interval) when Interval < 10 ->
    10;
limit_refresh_interval(Interval) ->
    Interval.

to_httpc_headers(Headers) ->
    [{binary_to_list(bin(K)), V} || {K, V} <- maps:to_list(Headers)].

cancel_http_request(#{request_id := undefined} = State) ->
    State;
cancel_http_request(#{request_id := RequestID} = State) ->
    ok = httpc:cancel_request(RequestID),
    receive
        {http, _} -> ok
    after 0 ->
        ok
    end,
    State#{request_id => undefined}.

bin(List) when is_list(List) ->
    unicode:characters_to_binary(List, utf8);
bin(Atom) when is_atom(Atom) ->
    erlang:atom_to_binary(Atom);
bin(Bin) when is_binary(Bin) ->
    Bin.
