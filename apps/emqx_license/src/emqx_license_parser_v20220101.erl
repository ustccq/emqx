%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license_parser_v20220101).

-behaviour(emqx_license_parser).

-include_lib("emqx/include/logger.hrl").
-include("emqx_license.hrl").

-define(DIGEST_TYPE, sha256).
-define(LICENSE_VERSION, <<"220111">>).
-define(MAX_EVALUATION_UPTIME_DAYS, 30).

%% This is the earliest license start date for version 220111
%% in theory it should  be the same as ?LICENSE_VERSION (20220111),
%% however, in order to make expiration test easier (before Mar.2022),
%% allow it to start from Nov.2021
-define(MIN_START_DATE, 20211101).

-export([
    parse/2,
    dump/1,
    summary/1,
    customer_type/1,
    license_type/1,
    expiry_date/1,
    max_sessions/1,
    max_uptime_seconds/1
]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

parse(Content, Key) ->
    case do_parse(Content) of
        {ok, {Payload, Signature}} ->
            case verify_signature(Payload, Signature, Key) of
                true -> parse_payload(Payload);
                false -> {error, invalid_signature}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

dump(
    #{
        type := Type,
        customer_type := CType,
        customer := Customer,
        email := Email,
        deployment := Deployment,
        date_start := DateStart,
        max_sessions := MaxSessions
    } = License
) ->
    DateExpiry = expiry_date(License),
    {DateNow, _} = calendar:universal_time(),
    Expiry = DateNow > DateExpiry,

    [
        {customer, Customer},
        {email, Email},
        {deployment, Deployment},
        {max_sessions, MaxSessions},
        {start_at, format_date(DateStart)},
        {expiry_at, format_date(DateExpiry)},
        {type, format_type(Type)},
        {customer_type, CType},
        {expiry, Expiry}
    ].

summary(
    #{
        deployment := Deployment,
        date_start := DateStart,
        max_sessions := MaxSessions
    } = License
) ->
    DateExpiry = expiry_date(License),
    #{
        deployment => Deployment,
        max_sessions => MaxSessions,
        start_at => format_date(DateStart),
        expiry_at => format_date(DateExpiry)
    }.

customer_type(#{customer_type := CType}) -> CType.

license_type(#{type := Type}) -> Type.

expiry_date(#{date_start := DateStart, days := Days}) ->
    calendar:gregorian_days_to_date(
        calendar:date_to_gregorian_days(DateStart) + Days
    ).

max_uptime_seconds(License) ->
    case customer_type(License) of
        ?EVALUATION_CUSTOMER ->
            ?MAX_EVALUATION_UPTIME_DAYS * 24 * 60 * 60;
        _ ->
            infinity
    end.

max_sessions(#{max_sessions := MaxSessions}) ->
    MaxSessions.

%%------------------------------------------------------------------------------
%% Private functions
%%------------------------------------------------------------------------------

do_parse(Content0) ->
    try
        Content = normalize(Content0),
        do_parse2(Content)
    catch
        _:_ ->
            {error, bad_license_format}
    end.

do_parse2(<<>>) ->
    {error, empty_string};
do_parse2(Content) ->
    [EncodedPayload, EncodedSignature] = binary:split(Content, <<".">>),
    Payload = base64:decode(EncodedPayload),
    Signature = base64:decode(EncodedSignature),
    {ok, {Payload, Signature}}.

%% drop whitespaces and newlines (CRLF)
normalize(Bin) ->
    <<<<C>> || <<C>> <= Bin, C =/= $\s andalso C =/= $\n andalso C =/= $\r>>.

verify_signature(Payload, Signature, Key) ->
    public_key:verify(Payload, ?DIGEST_TYPE, Signature, Key).

parse_payload(Payload) ->
    Lines = lists:map(
        fun string:trim/1,
        string:split(string:trim(Payload), <<"\n">>, all)
    ),
    case Lines of
        [?LICENSE_VERSION, Type, CType, Customer, Email, Deployment, DateStart, Days, MaxSessions] ->
            TypeParseRes = parse_type(Type),
            CTypeParseRes = parse_customer_type(CType),
            collect_fields([
                {type, TypeParseRes},
                {customer_type, CTypeParseRes},
                {customer, {ok, Customer}},
                {email, {ok, Email}},
                {deployment, {ok, Deployment}},
                {date_start, parse_date_start(DateStart)},
                {days, parse_days(Days)},
                {max_sessions, parse_max_sessions(TypeParseRes, CTypeParseRes, MaxSessions)}
            ]);
        [_Version, _Type, _CType, _Customer, _Email, _Deployment, _DateStart, _Days, _MaxSessions] ->
            {error, invalid_version};
        _ ->
            {error, unexpected_number_of_fields}
    end.

parse_type(TypeStr) ->
    case parse_int(TypeStr) of
        {ok, Type} -> {ok, Type};
        _ -> {error, invalid_license_type}
    end.

parse_customer_type(CTypeStr) ->
    case parse_int(CTypeStr) of
        {ok, CType} -> {ok, CType};
        _ -> {error, invalid_customer_type}
    end.

parse_date_start(DateStr) ->
    case parse_int(DateStr) of
        {ok, Num} when Num >= ?MIN_START_DATE ->
            Y = Num div 1_00_00,
            M = (Num rem 1_00_00) div 1_00,
            D = Num rem 1_00,
            case calendar:valid_date({Y, M, D}) of
                true -> {ok, {Y, M, D}};
                false -> {error, invalid_date}
            end;
        _ ->
            {error, invalid_date}
    end.

parse_days(DaysStr) ->
    case parse_int(DaysStr) of
        {ok, Days} when Days > 0 -> {ok, Days};
        _ -> {error, invalid_int_value}
    end.

parse_max_sessions(TypeParseRes, CTypeParseRes, MaxSessionsStr) ->
    case parse_int(MaxSessionsStr) of
        {ok, 0} ->
            {ok, resolve_default_max_sessions(TypeParseRes, CTypeParseRes)};
        {ok, MaxSessions} when MaxSessions > 0 ->
            {ok, MaxSessions};
        _ ->
            {error, invalid_connection_limit}
    end.

resolve_default_max_sessions({ok, ?COMMUNITY}, _) ->
    ?DEFAULT_MAX_SESSIONS_LTYPE2;
resolve_default_max_sessions(_, {ok, ?BUSINESS_CRITICAL_CUSTOMER}) ->
    ?DEFAULT_MAX_SESSIONS_CTYPE3;
resolve_default_max_sessions(_, {ok, ?EVALUATION_CUSTOMER}) ->
    ?DEFAULT_MAX_SESSIONS_CTYPE10;
resolve_default_max_sessions({ok, _}, {ok, _}) ->
    {error, invalid_connection_limit};
resolve_default_max_sessions(_BadType, _BadCType) ->
    {ok, 0}.

parse_int(Str0) ->
    Str = iolist_to_binary(string:replace(Str0, ",", "")),
    case string:to_integer(Str) of
        {Num, <<"">>} -> {ok, Num};
        _ -> error
    end.

collect_fields(Fields) ->
    Collected = lists:foldl(
        fun
            ({Name, {ok, Value}}, {FieldValues, Errors}) ->
                {[{Name, Value} | FieldValues], Errors};
            ({Name, {error, Reason}}, {FieldValues, Errors}) ->
                {FieldValues, [{Name, Reason} | Errors]}
        end,
        {[], []},
        Fields
    ),
    case Collected of
        {FieldValues, []} ->
            {ok, maps:from_list(FieldValues)};
        {_, Errors} ->
            {error, maps:from_list(Errors)}
    end.

format_date({Year, Month, Day}) ->
    iolist_to_binary(
        io_lib:format(
            "~4..0w-~2..0w-~2..0w",
            [Year, Month, Day]
        )
    ).

format_type(?COMMUNITY) -> <<"community">>;
format_type(?OFFICIAL) -> <<"official">>;
format_type(?TRIAL) -> <<"trial">>.
