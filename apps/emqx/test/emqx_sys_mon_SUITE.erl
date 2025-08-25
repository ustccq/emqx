%%--------------------------------------------------------------------
%% Copyright (c) 2019-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_sys_mon_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(SYSMON, emqx_sys_mon).

-define(FAKE_PORT, hd(erlang:ports())).
-define(FAKE_INFO, [{timeout, 100}, {in, foo}, {out, {?MODULE, bar, 1}}]).
-define(INPUTINFO, [
    {self(), long_gc, fmt("long_gc warning: pid = ~p", [self()]), ?FAKE_INFO},
    {self(), long_schedule, fmt("long_schedule warning: pid = ~p", [self()]), ?FAKE_INFO},
    {self(), large_heap, fmt("large_heap warning: pid = ~p", [self()]), ?FAKE_INFO},
    {
        self(),
        busy_port,
        fmt(
            "busy_port warning: suspid = ~p, port = ~p",
            [self(), ?FAKE_PORT]
        ),
        ?FAKE_PORT
    },
    %% for the case when the port is missing, for some
    %% reason.
    {
        self(),
        busy_port,
        fmt(
            "busy_port warning: suspid = ~p, port = ~p",
            [self(), []]
        ),
        []
    },
    {
        self(),
        busy_dist_port,
        fmt(
            "busy_dist_port warning: suspid = ~p, port = ~p",
            [self(), ?FAKE_PORT]
        ),
        ?FAKE_PORT
    },
    {?FAKE_PORT, long_schedule, fmt("long_schedule warning: port = ~p", [?FAKE_PORT]), ?FAKE_INFO}
]).

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_testcase(t_sys_mon = TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx, #{
                override_env => [
                    {sys_mon, [
                        {busy_dist_port, true},
                        {busy_port, false},
                        {large_heap, 8388608},
                        {long_schedule, 240},
                        {long_gc, 0}
                    ]}
                ]
            }}
        ],
        #{work_dir => emqx_cth_suite:work_dir(TestCase, Config)}
    ),
    [{apps, Apps} | Config];
init_per_testcase(t_sys_mon2 = TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx, #{
                override_env => [
                    {sys_mon, [
                        {busy_dist_port, false},
                        {busy_port, true},
                        {large_heap, 8388608},
                        {long_schedule, 0},
                        {long_gc, 200},
                        {nothing, 0}
                    ]}
                ]
            }}
        ],
        #{work_dir => emqx_cth_suite:work_dir(TestCase, Config)}
    ),
    [{apps, Apps} | Config];
init_per_testcase(t_procinfo = TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [emqx],
        #{work_dir => emqx_cth_suite:work_dir(TestCase, Config)}
    ),
    ok = meck:new(emqx_vm, [passthrough, no_history]),
    [{apps, Apps} | Config];
init_per_testcase(TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [emqx],
        #{work_dir => emqx_cth_suite:work_dir(TestCase, Config)}
    ),
    [{apps, Apps} | Config].

end_per_testcase(t_procinfo, Config) ->
    Apps = ?config(apps, Config),
    ok = meck:unload(emqx_vm),
    ok = emqx_cth_suite:stop(Apps),
    ok;
end_per_testcase(_, Config) ->
    Apps = ?config(apps, Config),
    ok = emqx_cth_suite:stop(Apps),
    ok.

t_procinfo(_) ->
    ok = meck:expect(emqx_vm, get_process_info, fun(_) -> [] end),
    ok = meck:expect(emqx_vm, get_process_gc_info, fun(_) -> undefined end),
    ?assertEqual([{pid, self()}], emqx_sys_mon:procinfo(self())).

t_procinfo_initial_call_and_stacktrace(_) ->
    SomePid = proc_lib:spawn(?MODULE, some_function, [self(), arg2]),
    receive
        {spawned, SomePid} ->
            ok
    after 100 ->
        error(process_not_spawned)
    end,
    ProcInfo = emqx_sys_mon:procinfo(SomePid),
    ?assertEqual(
        {?MODULE, some_function, ['Argument__1', 'Argument__2']},
        proplists:get_value(proc_lib_initial_call, ProcInfo)
    ),
    ?assertMatch(
        [
            {?MODULE, some_function, 2, [
                {file, _},
                {line, _}
            ]},
            {proc_lib, init_p_do_apply, 3, [
                {file, _},
                {line, _}
            ]}
        ],
        proplists:get_value(current_stacktrace, ProcInfo)
    ),
    SomePid ! stop.

t_sys_mon(_Config) ->
    lists:foreach(
        fun({PidOrPort, SysMonName, ValidateInfo, InfoOrPort}) ->
            validate_sys_mon_info(PidOrPort, SysMonName, ValidateInfo, InfoOrPort)
        end,
        ?INPUTINFO
    ).

%% Existing port, but closed.
t_sys_mon_dead_port(_Config) ->
    process_flag(trap_exit, true),
    Port = dead_port(),
    {PidOrPort, SysMonName, ValidateInfo, InfoOrPort} =
        {
            self(),
            busy_port,
            fmt(
                "busy_port warning: suspid = ~p, port = ~p",
                [self(), Port]
            ),
            Port
        },
    validate_sys_mon_info(PidOrPort, SysMonName, ValidateInfo, InfoOrPort).

t_sys_mon2(_Config) ->
    ?SYSMON ! {timeout, ignored, reset},
    ?SYSMON ! {ignored},
    ?assertEqual(ignored, gen_server:call(?SYSMON, ignored)),
    ?assertEqual(ok, gen_server:cast(?SYSMON, ignored)),
    gen_server:stop(?SYSMON).

validate_sys_mon_info(PidOrPort, SysMonName, ValidateInfo, InfoOrPort) ->
    {ok, C} = emqtt:start_link([{host, "localhost"}]),
    {ok, _} = emqtt:connect(C),
    emqtt:subscribe(C, emqx_topic:systop(lists:concat(['sysmon/', SysMonName])), qos1),
    timer:sleep(100),
    ?SYSMON ! {monitor, PidOrPort, SysMonName, InfoOrPort},
    receive
        {publish, #{payload := Info}} ->
            ?assertEqual(ValidateInfo, binary_to_list(Info)),
            ct:pal("OK - received msg: ~p~n", [Info])
    after 1000 ->
        ct:fail(timeout)
    end,
    emqtt:stop(C).

fmt(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).

some_function(Parent, _Arg2) ->
    Parent ! {spawned, self()},
    receive
        stop ->
            ok
    end.

dead_port() ->
    Port = erlang:open_port({spawn, "ls"}, []),
    exit(Port, kill),
    Port.
