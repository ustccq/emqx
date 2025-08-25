%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_connector_jwt).

-include("emqx_connector_jwt_tables.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("jose/include/jose_jwt.hrl").
-include_lib("jose/include/jose_jws.hrl").

%% API
-export([
    lookup_jwt/1,
    lookup_jwt/2,
    delete_jwt/2,
    ensure_jwt/1
]).

-type jwt() :: binary().
-type wrapped_jwk() :: fun(() -> jose_jwk:key()).
-type jwk() :: jose_jwk:key().
-type duration() :: non_neg_integer().

-type jwt_config() :: local_jwt_config() | external_jwt_config().
-type local_jwt_config() :: #{
    %% Time before expiration we consider the token already expired.
    grace_period => non_neg_integer(),
    expiration := duration(),
    resource_id := resource_id(),
    table => ets:table(),
    jwk := wrapped_jwk() | jwk(),
    iss := binary(),
    sub := binary(),
    aud := binary(),
    kid := binary(),
    alg := binary()
}.
-type external_jwt_config() :: #{
    table => ets:table(),
    %% Time before expiration we consider the token already expired.
    grace_period => non_neg_integer(),
    generate_fn := {module(), atom(), [term()]} | fun(() -> iodata())
}.

-export_type([jwt_config/0, jwt/0]).

-spec lookup_jwt(resource_id()) -> {ok, jwt()} | {error, not_found}.
lookup_jwt(ResourceId) ->
    ?MODULE:lookup_jwt(?JWT_TABLE, ResourceId).

-spec lookup_jwt(ets:table(), resource_id()) -> {ok, jwt()} | {error, not_found}.
lookup_jwt(TId, ResourceId) ->
    try
        case ets:lookup(TId, {ResourceId, jwt}) of
            [{{ResourceId, jwt}, JWT}] ->
                {ok, JWT};
            [] ->
                {error, not_found}
        end
    catch
        error:badarg ->
            {error, not_found}
    end.

-spec delete_jwt(ets:table(), resource_id()) -> ok.
delete_jwt(TId, ResourceId) ->
    try
        ets:delete(TId, {ResourceId, jwt}),
        ?tp(connector_jwt_deleted, #{}),
        ok
    catch
        error:badarg ->
            ok
    end.

%% @doc Attempts to retrieve a valid JWT from the cache.  If there is
%% none or if the cached token is expired, generates an caches a fresh
%% one.
-spec ensure_jwt(jwt_config()) -> jwt().
ensure_jwt(JWTConfig) ->
    #{resource_id := ResourceId} = JWTConfig,
    Table = maps:get(table, JWTConfig, ?JWT_TABLE),
    case lookup_jwt(Table, ResourceId) of
        {error, not_found} ->
            JWT = do_generate_jwt(JWTConfig),
            store_jwt(JWTConfig, JWT),
            JWT;
        {ok, JWT0} ->
            case is_about_to_expire(JWTConfig, JWT0) of
                true ->
                    JWT = do_generate_jwt(JWTConfig),
                    store_jwt(JWTConfig, JWT),
                    JWT;
                false ->
                    JWT0
            end
    end.

%%-----------------------------------------------------------------------------------------
%% Helper fns
%%-----------------------------------------------------------------------------------------

-spec do_generate_jwt(jwt_config()) -> jwt().
do_generate_jwt(#{generate_fn := GenerateFn}) ->
    JWT = GenerateFn(),
    %% Assert iodata
    _ = iolist_size(JWT),
    JWT;
do_generate_jwt(#{
    expiration := ExpirationMS,
    iss := Iss,
    sub := Sub,
    aud := Aud,
    kid := KId,
    alg := Alg,
    jwk := WrappedJWK
}) ->
    JWK = emqx_secret:unwrap(WrappedJWK),
    Headers = #{
        <<"alg">> => Alg,
        <<"kid">> => KId
    },
    Now = erlang:system_time(seconds),
    ExpirationS = erlang:convert_time_unit(ExpirationMS, millisecond, second),
    Claims = #{
        <<"iss">> => Iss,
        <<"sub">> => Sub,
        <<"aud">> => Aud,
        <<"iat">> => Now,
        <<"exp">> => Now + ExpirationS
    },
    JWT0 = jose_jwt:sign(JWK, Headers, Claims),
    {_, JWT} = jose_jws:compact(JWT0),
    JWT.

-spec store_jwt(jwt_config(), jwt()) -> ok.
store_jwt(#{resource_id := ResourceId} = JWTConfig, JWT) ->
    Table = maps:get(table, JWTConfig, ?JWT_TABLE),
    true = ets:insert(Table, {{ResourceId, jwt}, JWT}),
    ?tp(emqx_connector_jwt_token_stored, #{resource_id => ResourceId}),
    ok.

-spec is_about_to_expire(jwt_config(), jwt()) -> boolean().
is_about_to_expire(JWTConfig, JWT) ->
    GracePeriodS = maps:get(grace_period, JWTConfig, 5),
    #jose_jwt{fields = #{<<"exp">> := Exp}} = jose_jwt:peek(JWT),
    Now = erlang:system_time(seconds),
    GraceExp = Exp - GracePeriodS,
    Now >= GraceExp.
