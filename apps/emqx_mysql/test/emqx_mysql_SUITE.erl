%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_mysql_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MYSQL_HOST, "mysql").
-define(MYSQL_USER, "root").
-define(MYSQL_PASSWORD, "public").
-define(MYSQL_RESOURCE_MOD, emqx_mysql).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    case emqx_common_test_helpers:is_tcp_server_available(?MYSQL_HOST, ?MYSQL_DEFAULT_PORT) of
        true ->
            Apps = emqx_cth_suite:start(
                [emqx_conf, emqx_connector],
                #{work_dir => emqx_cth_suite:work_dir(Config)}
            ),
            [{apps, Apps} | Config];
        false ->
            {skip, no_mysql}
    end.

end_per_suite(Config) ->
    ok = emqx_cth_suite:stop(proplists:get_value(apps, Config)).

% %%------------------------------------------------------------------------------
% %% Testcases
% %%------------------------------------------------------------------------------

t_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_mysql_SUITE">>,
        mysql_config()
    ).

t_lifecycle_passwordless(_Config) ->
    perform_lifecycle_check(
        <<"emqx_mysql_SUITE:passwordless">>,
        mysql_config(passwordless)
    ).

perform_lifecycle_check(ResourceId, InitialConfig) ->
    {ok, #{config := CheckedConfig}} =
        emqx_resource:check_config(?MYSQL_RESOURCE_MOD, InitialConfig),
    {ok, #{
        state := #{pool_name := PoolName} = State,
        status := InitialStatus
    }} = emqx_resource:create_local(
        ResourceId,
        ?CONNECTOR_RESOURCE_GROUP,
        ?MYSQL_RESOURCE_MOD,
        CheckedConfig,
        #{spawn_buffer_workers => true}
    ),
    ?assertEqual(InitialStatus, connected),
    % Instance should match the state and status of the just started resource
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := InitialStatus
    }} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual({ok, connected}, emqx_resource:health_check(ResourceId)),
    % % Perform query as further check that the resource is working as expected
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_no_params())),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_with_params())),
    ?assertMatch(
        {ok, _, [[1]]},
        emqx_resource:query(
            ResourceId,
            test_query_with_params_and_timeout()
        )
    ),
    ?assertEqual(ok, emqx_resource:stop(ResourceId)),
    % Resource will be listed still, but state will be changed and healthcheck will fail
    % as the worker no longer exists.
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := StoppedStatus
    }} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual(stopped, StoppedStatus),
    ?assertEqual({error, resource_is_stopped}, emqx_resource:health_check(ResourceId)),
    % Resource healthcheck shortcuts things by checking ets. Go deeper by checking pool itself.
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(PoolName)),
    % Can call stop/1 again on an already stopped instance
    ?assertEqual(ok, emqx_resource:stop(ResourceId)),
    % Make sure it can be restarted and the healthchecks and queries work properly
    ?assertEqual(ok, emqx_resource:restart(ResourceId)),
    % async restart, need to wait resource
    timer:sleep(500),
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{status := InitialStatus}} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual({ok, connected}, emqx_resource:health_check(ResourceId)),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_no_params())),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_with_params())),
    ?assertMatch(
        {ok, _, [[1]]},
        emqx_resource:query(
            ResourceId,
            test_query_with_params_and_timeout()
        )
    ),
    % Stop and remove the resource in one go.
    ?assertEqual(ok, emqx_resource:remove_local(ResourceId)),
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(PoolName)),
    % Should not even be able to get the resource data out of ets now unlike just stopping.
    ?assertEqual({error, not_found}, emqx_resource:get_instance(ResourceId)).

% %%------------------------------------------------------------------------------
% %% Helpers
% %%------------------------------------------------------------------------------

mysql_config() ->
    mysql_config(default).

mysql_config(default) ->
    parse_mysql_config(
        "\n  auto_reconnect = true"
        "\n  database = mqtt"
        "\n  username = ~p"
        "\n  password = ~p"
        "\n  pool_size = 8"
        "\n  server = \"~s:~b\""
        "\n",
        [?MYSQL_USER, ?MYSQL_PASSWORD, ?MYSQL_HOST, ?MYSQL_DEFAULT_PORT]
    );
mysql_config(passwordless) ->
    ok = run_admin_query("CREATE USER IF NOT EXISTS 'nopwd'@'%'"),
    ok = run_admin_query("GRANT ALL ON mqtt.* TO 'nopwd'@'%'"),
    parse_mysql_config(
        "\n  auto_reconnect = true"
        "\n  database = mqtt"
        "\n  username = nopwd"
        "\n  pool_size = 8"
        "\n  server = \"~s:~b\""
        "\n",
        [?MYSQL_HOST, ?MYSQL_DEFAULT_PORT]
    ).

parse_mysql_config(FormatString, Args) ->
    {ok, Config} = hocon:binary(io_lib:format(FormatString, Args)),
    #{<<"config">> => Config}.

run_admin_query(Query) ->
    Pid = connect_mysql(),
    try
        mysql:query(Pid, Query)
    after
        mysql:stop(Pid)
    end.

connect_mysql() ->
    Opts = [
        {host, ?MYSQL_HOST},
        {port, ?MYSQL_DEFAULT_PORT},
        {user, ?MYSQL_USER},
        {password, ?MYSQL_PASSWORD},
        {database, "mysql"}
    ],
    {ok, Pid} = mysql:start_link(Opts),
    Pid.

test_query_no_params() ->
    {sql, <<"SELECT 1">>}.

test_query_with_params() ->
    {sql, <<"SELECT ?">>, [1]}.

test_query_with_params_and_timeout() ->
    {sql, <<"SELECT ?">>, [1], 1000}.
