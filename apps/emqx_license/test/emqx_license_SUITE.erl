%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx_license.hrl").
-include_lib("emqx/include/emqx_config.hrl").

-define(LIMIT, 10).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_license_test_lib:mock_parser(),
    Apps = emqx_cth_suite:start(
        [
            emqx,
            emqx_conf,
            {emqx_license, "license { key = \"default\" }"}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{suite_apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_license_test_lib:unmock_parser(),
    ok = emqx_cth_suite:stop(?config(suite_apps, Config)).

init_per_testcase(Case, Config) ->
    setup_test(Case, Config) ++ Config.

end_per_testcase(Case, Config) ->
    teardown_test(Case, Config).

setup_test(_TestCase, _Config) ->
    [].

teardown_test(_TestCase, _Config) ->
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_update_value(_Config) ->
    ?assertMatch(
        {error, #{parse_results := [_ | _]}},
        emqx_license:update_key("invalid.license")
    ),

    LicenseValue = emqx_license_test_lib:default_test_license(),

    ?assertMatch(
        {ok, #{}},
        emqx_license:update_key(LicenseValue)
    ).

t_check_exceeded_25(_Config) ->
    Limit = ?NO_OVERSHOOT_SESSIONS_LIMIT,
    check_exceeded(Limit, Limit).

t_check_exceeded_26(_Config) ->
    Limit = ?NO_OVERSHOOT_SESSIONS_LIMIT + 1,
    Factor = ?SESSIONS_LIMIT_OVERSHOOT_FACTOR,
    check_exceeded(Limit, erlang:round(Limit * Factor)).

check_exceeded(LimitInLicense, Limit) ->
    License = mk_license(integer_to_list(LimitInLicense)),
    #{} = update(License),
    ClientIdFn = fun(I) -> bin(["c-", i2l(I), "-of-", i2l(Limit)]) end,
    Pids = lists:map(fun(I) -> connect([{clientid, ClientIdFn(I)}]) end, lists:seq(1, Limit)),
    sync_cache(),
    ?assertEqual({stop, {error, ?RC_QUOTA_EXCEEDED}}, check()),
    ClientId1 = ClientIdFn(1),
    ClientId9 = ClientIdFn(9),
    ?assertEqual({ok, #{}}, check(#{clientid => ClientId1})),
    ?assertEqual({ok, #{}}, check(#{clientid => ClientId9})),
    ok = lists:foreach(fun(Pid) -> emqtt:stop(Pid) end, Pids).

t_check_exceeded_non_clean(_Config) ->
    ?assertEqual(0, emqx_cm:get_sessions_count()),
    License = mk_license(),
    #{} = update(License),
    Properties = #{'Session-Expiry-Interval' => 10},
    IDs = [iolist_to_binary(["test-client-", integer_to_list(I)]) || I <- lists:seq(1, ?LIMIT)],
    Pids = lists:map(
        fun(Id) -> connect([{clientid, Id}, {proto_ver, v5}, {properties, Properties}]) end, IDs
    ),
    sync_cache(),
    ?assertEqual({stop, {error, ?RC_QUOTA_EXCEEDED}}, check()),
    ok = lists:foreach(fun(Pid) -> emqtt:stop(Pid) end, Pids),
    %% wait until all clients disconnected
    ?retry(100, 50, ?assertEqual(0, emqx_cm:get_connected_client_count())),
    ?assertEqual(?LIMIT, emqx_cm:get_sessions_count()),
    %% continue to expect quota exceeded
    ?assertEqual({stop, {error, ?RC_QUOTA_EXCEEDED}}, check()),
    lists:foreach(fun emqx_cm:kick_session/1, IDs),
    ?retry(100, 50, ?assertEqual(0, emqx_cm:get_sessions_count())),
    ok.

t_check_ok(_Config) ->
    License = mk_license(),
    #{} = update(License),

    Pids = lists:map(
        fun(I) ->
            {ok, C} = emqtt:start_link([{proto_ver, v5}]),
            ?assertMatch({I, {ok, _}}, {I, emqtt:connect(C)}),
            C
        end,
        lists:seq(1, ?LIMIT)
    ),
    ?assertEqual({ok, #{}}, check()),
    ok = lists:foreach(fun(Pid) -> emqtt:stop(Pid) end, Pids).

t_check_expired(_Config) ->
    {_, License} = mk_license(
        [
            "220111",
            %% Official customer
            "1",
            %% Small customer
            "0",
            "Foo",
            "contact@foo.com",
            "bar",
            %% Expired long ago
            "20211101",
            % days
            "10",
            % sessions
            "10"
        ]
    ),
    #{} = update(License),

    ?assertEqual({stop, {error, ?RC_QUOTA_EXCEEDED}}, check()).

t_check_max_uptime_reached(_Config) ->
    {_, License} = mk_license(
        [
            "220111",
            "0",
            "10",
            "Foo",
            "contact@foo.com",
            "bar",
            "20991231",
            "1",
            "123"
        ]
    ),

    meck:new(emqx_license_parser_v20220101, [passthrough, no_history]),
    meck:expect(emqx_license_parser_v20220101, max_uptime_seconds, fun(_) -> 0 end),

    #{} = update(License),

    meck:unload(emqx_license_parser_v20220101),

    ?assertEqual(
        {stop, {error, ?RC_QUOTA_EXCEEDED}},
        emqx_license:check(#{clientid => <<>>}, #{})
    ).

t_check_not_loaded(_Config) ->
    ok = emqx_license_checker:purge(),
    ?assertEqual({stop, {error, ?RC_QUOTA_EXCEEDED}}, check()).

t_import_config(_Config) ->
    %% Import default license
    ?assertMatch(
        {ok, #{root_key := license, changed := _}},
        import_config(#{<<"license">> => #{<<"key">> => <<"default">>}})
    ),
    ?assertEqual(default, emqx:get_config([license, key])),
    ?assertMatch(
        {ok, #{max_sessions := ?DEFAULT_MAX_SESSIONS_LTYPE2}}, emqx_license_checker:limits()
    ),

    %% Import evaluation license
    ?assertMatch(
        {ok, #{root_key := license, changed := _}},
        import_config(#{<<"license">> => #{<<"key">> => <<"evaluation">>}})
    ),
    ?assertEqual(evaluation, emqx:get_config([license, key])),
    ?assertMatch(
        {ok, #{max_sessions := ?DEFAULT_MAX_SESSIONS_CTYPE10}}, emqx_license_checker:limits()
    ),

    %% Import to a new license
    EncodedLicense = emqx_license_test_lib:make_license(#{
        license_type => "1", max_sessions => "0", customer_type => "3"
    }),
    ?assertMatch(
        {ok, #{root_key := license, changed := _}},
        import_config(
            #{
                <<"license">> =>
                    #{
                        <<"key">> => EncodedLicense,
                        <<"connection_low_watermark">> => <<"20%">>,
                        <<"connection_high_watermark">> => <<"50%">>
                    }
            }
        )
    ),
    ?assertMatch(
        {ok, #{max_sessions := ?DEFAULT_MAX_SESSIONS_CTYPE3}}, emqx_license_checker:limits()
    ),
    ?assertMatch(
        #{type := <<"official">>, max_sessions := ?DEFAULT_MAX_SESSIONS_CTYPE3},
        maps:from_list(emqx_license_checker:dump())
    ),
    ?assertMatch(
        #{connection_low_watermark := 0.2, connection_high_watermark := 0.5},
        emqx:get_config([license])
    ).

t_app_cannot_start_with_invalid_license(_Config) ->
    meck:new(emqx_license, [passthrough, no_history]),
    meck:expect(emqx_license, read_license, fun() -> {error, 'SINGLE_NODE_LICENSE'} end),
    try
        ?assertMatch(
            {error, "SINGLE_NODE_LICENSE," ++ _}, emqx_license_app:start(normal, permanent)
        )
    after
        meck:unload(emqx_license)
    end.

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

%% Make a test license valid for 100,000 days with max connections 10
mk_license() ->
    mk_license(integer_to_list(?LIMIT)).

mk_license([[_ | _] | _] = Fields) ->
    EncodedLicense = emqx_license_test_lib:make_license(Fields),
    {ok, License} = emqx_license_parser:parse(
        EncodedLicense,
        emqx_license_test_lib:public_key_pem()
    ),
    {EncodedLicense, License};
mk_license(Limit) ->
    {_, License} = mk_license(
        [
            "220111",
            "0",
            "10",
            "Foo",
            "contact@foo.com",
            "bar",
            "20220111",
            % days
            "100000",
            Limit
        ]
    ),
    License.

update(License) ->
    Result = emqx_license_checker:update(License),
    sync_cache(),
    Result.

sync_cache() ->
    %% force refresh the cache
    _ = whereis(emqx_license_resources) ! update_resources,
    %% force sync with the process
    _ = sys:get_state(whereis(emqx_license_resources)),
    ok.

i2l(I) -> integer_to_list(I).
bin(X) -> iolist_to_binary(X).

check() ->
    check(#{clientid => <<>>}).

check(ConnInfo) ->
    emqx_license:check(ConnInfo, #{}).

connect() ->
    connect([]).

connect(Opts) ->
    {ok, C} = emqtt:start_link(Opts),
    unlink(C),
    {ok, _} = emqtt:connect(C),
    C.

import_config(RawConf) ->
    emqx_license:import_config(?global_ns, RawConf).
