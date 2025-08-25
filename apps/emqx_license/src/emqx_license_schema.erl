%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license_schema).

-include("emqx_license.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

%%------------------------------------------------------------------------------
%% hocon_schema callbacks
%%------------------------------------------------------------------------------

-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1, validations/0, desc/1, tags/0]).

-export([
    default_setting/0
]).

namespace() -> "license".

roots() ->
    [
        {license,
            hoconsc:mk(
                hoconsc:ref(?MODULE, key_license),
                #{
                    desc => ?DESC(license_root)
                }
            )}
    ].

tags() ->
    [<<"License">>].

fields(key_license) ->
    [
        {key, #{
            type => hoconsc:union([default, evaluation, binary()]),
            default => <<"default">>,
            %% so it's not logged
            sensitive => true,
            required => true,
            desc => ?DESC(key_field)
        }},
        %% This feature is not made GA yet, hence hidden.
        %% When license is issued to cutomer-type BUSINESS_CRITICAL (code 3)
        %% This config is taken as the real max_sessions limit.
        {dynamic_max_connections, #{
            type => non_neg_integer(),
            default => default(dynamic_max_connections),
            required => false,
            importance => ?IMPORTANCE_HIDDEN,
            desc => ?DESC(dynamic_max_connections)
        }},
        {connection_low_watermark, #{
            type => emqx_schema:percent(),
            default => default(connection_low_watermark),
            example => default(connection_low_watermark),
            desc => ?DESC(connection_low_watermark_field)
        }},
        {connection_high_watermark, #{
            type => emqx_schema:percent(),
            default => default(connection_high_watermark),
            example => default(connection_high_watermark),
            desc => ?DESC(connection_high_watermark_field)
        }}
    ].

desc(key_license) ->
    "License provisioned as a string.";
desc(_) ->
    undefined.

validations() ->
    [{check_license_watermark, fun check_license_watermark/1}].

check_license_watermark(Conf) ->
    case hocon_maps:get("license.connection_low_watermark", Conf) of
        undefined ->
            true;
        Low ->
            case hocon_maps:get("license.connection_high_watermark", Conf) of
                undefined ->
                    {bad_license_watermark, #{high => undefined, low => Low}};
                High ->
                    {ok, HighFloat} = emqx_schema:to_percent(High),
                    {ok, LowFloat} = emqx_schema:to_percent(Low),
                    case HighFloat > LowFloat of
                        true -> true;
                        false -> {bad_license_watermark, #{high => High, low => Low}}
                    end
            end
    end.

%% @doc Exported for testing
default_setting() ->
    Keys =
        [
            connection_low_watermark,
            connection_high_watermark,
            dynamic_max_connections
        ],
    maps:from_list(
        lists:map(
            fun(K) ->
                {K, default(K)}
            end,
            Keys
        )
    ).

default(connection_low_watermark) ->
    <<"75%">>;
default(connection_high_watermark) ->
    <<"80%">>;
default(dynamic_max_connections) ->
    %% This config is only applicable to CTYPE3
    ?DEFAULT_MAX_SESSIONS_CTYPE3.
