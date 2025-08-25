%%--------------------------------------------------------------------
%% Copyright (c) 2019-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_connection_conninfo_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx,
                "listeners.tcp.default {\n"
                "   tcp_options {\n"
                "       recbuf = 10\n"
                "       buffer = 10\n"
                "       active_n = 1\n"
                "   }\n"
                "   messages_rate = \"1/1s\"\n"
                "   bytes_rate = \"1KB/1s\"\n"
                "}\n"}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Case, Config)}
    ),
    [{apps, Apps} | Config].

end_per_testcase(_Case, Config) ->
    emqx_cth_suite:stop(?config(apps, Config)).

t_inconsistent_chan_info(_Config) ->
    {ok, C} = emqtt:start_link([{clientid, emqx_guid:to_hexstr(emqx_guid:gen())}]),
    {ok, _} = emqtt:connect(C),
    ok = emqtt:disconnect(C),

    ClientIds = [
        ClientId
     || {ClientId, _ChanPid, _ConnState, _ConnInfo, _ClientInfo} <- emqx_utils_stream:consume(
            emqx_cm:all_channels_stream([emqx_connection])
        )
    ],

    ?assertNot(lists:member(undefined, ClientIds)).
