%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_snowflake_aggregated_impl).

-feature(maybe_expr, enable).

-behaviour(emqx_resource).
-behaviour(emqx_connector_aggreg_delivery).

-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx/include/emqx_trace.hrl").
-include("emqx_bridge_snowflake.hrl").
-include_lib("emqx_connector_aggregator/include/emqx_connector_aggregator.hrl").
-include_lib("emqx_connector_jwt/include/emqx_connector_jwt_tables.hrl").

-elvis([{elvis_style, macro_module_names, disable}]).

%% `emqx_resource' API
-export([
    resource_type/0,
    callback_mode/0,

    on_start/2,
    on_stop/2,
    on_get_status/2,

    on_get_channels/1,
    on_add_channel/4,
    on_remove_channel/3,
    on_get_channel_status/3,

    on_query/3,
    on_batch_query/3
]).

%% `ecpool_worker' API
-export([
    connect/1,
    disconnect/1,
    do_health_check_connector/1,
    do_stage_file/6,
    do_get_login_failure_details/2
]).

%% `emqx_connector_aggreg_delivery' API
-export([
    init_transfer_state_and_container_opts/2,
    process_append/2,
    process_write/1,
    process_complete/1,
    process_terminate/1,
    process_format_status/1
]).

%% API
-export([
    insert_report/2
]).

%% Internal exports only for mocking
-export([
    %% Aggregated mode
    do_insert_files_request/4,
    do_insert_report_request/4
]).

%%------------------------------------------------------------------------------
%% Type declarations
%%------------------------------------------------------------------------------

%% Allocatable resources
-define(aggregated_http_pool(RES_ID), {aggregated_http_pool, RES_ID}).
-define(aggregated_delivery_sup(RES_ID), {aggregated_delivery_sup, RES_ID}).

-define(HC_TIMEOUT, 15_000).
%% Seconds
-define(AUTO_RECONNECT_INTERVAL, 2).

%% Ad-hoc requests
-record(insert_report, {action_res_id :: action_resource_id(), opts :: ad_hoc_query_opts()}).

-type connector_config() :: #{
    server := binary(),
    account := account(),
    username := binary(),
    password => emqx_schema_secret:secret(),
    private_key_path => binary(),
    private_key_password => emqx_schema_secret:secret(),
    dsn := binary(),
    pool_size := pos_integer(),
    proxy := none | proxy_config()
}.
-type connector_state() :: #{
    account := account(),
    server := #{host := binary(), port := emqx_schema:port_number()},
    installed_actions := #{action_resource_id() => action_state()}
}.

-type action_config() :: #{
    parameters := #{
        database := database(),
        schema := schema(),
        pipe := pipe(),
        pipe_user := binary(),
        private_key := emqx_schema_secret:secret(),
        connect_timeout := emqx_schema:timeout_duration(),
        pipelining := non_neg_integer(),
        pool_size := pos_integer(),
        max_retries := non_neg_integer()
    }
}.
-type action_state() :: #{
    ?mode := ?aggregated,
    aggreg_id := term(),
    supervisor := pid()
}.

-type account() :: binary().
-type database() :: binary().
-type schema() :: binary().
-type stage() :: binary().
-type pipe() :: binary().

-type proxy_config() :: #{
    host := binary(),
    port := emqx_schema:port_number()
}.

-type odbc_pool() :: connector_resource_id().
-type http_pool() :: action_resource_id().
-type http_client_config() :: #{
    jwt_config := emqx_connector_jwt:jwt_config(),
    insert_files_path := binary(),
    insert_report_path := binary(),
    max_retries := non_neg_integer(),
    request_ttl := timeout()
}.

-type query() :: action_query() | insert_report_query().
-type action_query() :: {_Tag :: channel_id(), _Data :: map()}.
-type insert_report_query() :: #insert_report{}.

-type ad_hoc_query_opts() :: map().

-type action_name() :: binary().

-type transfer_opts() :: #{
    container := #{type := emqx_connector_aggregator:container_type()},
    upload_options := #{
        action := action_name(),
        database := database(),
        schema := schema(),
        stage := stage(),
        odbc_pool := odbc_pool(),
        http_pool := http_pool(),
        http_client_config := http_client_config(),
        min_block_size := pos_integer(),
        max_block_size := pos_integer(),
        work_dir := file:filename()
    }
}.

-type transfer_state() :: #{
    action_name := action_name(),

    buffer_seq := non_neg_integer(),
    buffer_datetime := string(),
    seq_no := non_neg_integer(),
    container_type := emqx_connector_aggregator:container_type(),

    http_pool := http_pool(),
    http_client_config := http_client_config(),

    odbc_pool := odbc_pool(),
    database := database(),
    schema := schema(),
    stage := stage(),
    filename_template := emqx_template:t(),
    filename := emqx_maybe:t(file:filename()),
    fd := emqx_maybe:t(file:io_device()),
    work_dir := file:filename(),
    written := non_neg_integer(),
    staged_files := [staged_file()],
    next_file := queue:queue({file:filename(), non_neg_integer()}),

    max_block_size := pos_integer(),
    min_block_size := pos_integer()
}.
-type staged_file() :: #{
    path := file:filename(),
    size := non_neg_integer()
}.

%%------------------------------------------------------------------------------
%% `emqx_resource' API
%%------------------------------------------------------------------------------

-spec resource_type() -> atom().
resource_type() ->
    snowflake_aggregated.

-spec callback_mode() -> callback_mode().
callback_mode() ->
    always_sync.

-spec on_start(connector_resource_id(), connector_config()) ->
    {ok, connector_state()} | {error, _Reason}.
on_start(ConnResId, ConnConfig) ->
    #{
        server := Server,
        account := Account,
        dsn := DSN,
        pool_size := PoolSize,
        proxy := ProxyConfig
    } = ConnConfig,
    #{hostname := Host, port := Port} = emqx_schema:parse_server(Server, ?SERVER_OPTS),
    Username = maps:get(username, ConnConfig, undefined),
    Authn = mk_odbc_authn_opt(ConnConfig),
    PoolOpts = lists:flatten([
        Authn,
        {pool_size, PoolSize},
        {dsn, DSN},
        {account, Account},
        {server, Server},
        [{username, Username} || Username /= undefined],
        {proxy, ProxyConfig},
        {on_disconnect, {?MODULE, disconnect, []}}
    ]),
    case emqx_resource_pool:start(ConnResId, ?MODULE, PoolOpts) of
        ok ->
            State = #{
                account => Account,
                server => #{host => Host, port => Port},
                installed_actions => #{}
            },
            {ok, State};
        {error, {start_pool_failed, _, Reason}} ->
            {error, Reason}
    end.

-spec on_stop(connector_resource_id(), connector_state()) -> ok.
on_stop(ConnResId, _ConnState) ->
    aggregated_destroy_allocated_resources(ConnResId),
    Res = emqx_resource_pool:stop(ConnResId),
    ?tp("snowflake_connector_stop", #{instance_id => ConnResId}),
    Res.

-spec on_get_status(connector_resource_id(), connector_state()) ->
    ?status_connected | ?status_disconnected.
on_get_status(ConnResId, _ConnState) ->
    health_check_connector(ConnResId).

-spec on_add_channel(
    connector_resource_id(),
    connector_state(),
    action_resource_id(),
    action_config()
) ->
    {ok, connector_state()}.
on_add_channel(ConnResId, ConnState0, ActionResId, ActionConfig) ->
    maybe
        {ok, ActionState} ?= create_action(ConnResId, ActionResId, ActionConfig, ConnState0),
        ConnState = emqx_utils_maps:deep_put(
            [installed_actions, ActionResId], ConnState0, ActionState
        ),
        {ok, ConnState}
    end.

-spec on_remove_channel(
    connector_resource_id(),
    connector_state(),
    action_resource_id()
) ->
    {ok, connector_state()}.
on_remove_channel(
    ConnResId, ConnState0 = #{installed_actions := InstalledActions0}, ActionResId
) when
    is_map_key(ActionResId, InstalledActions0)
->
    {ActionState, InstalledActions} = maps:take(ActionResId, InstalledActions0),
    destroy_action(ConnResId, ActionResId, ActionState),
    ConnState = ConnState0#{installed_actions := InstalledActions},
    {ok, ConnState};
on_remove_channel(_ConnResId, ConnState, ActionResId) ->
    ensure_common_action_destroyed(ActionResId),
    {ok, ConnState}.

-spec on_get_channels(connector_resource_id()) ->
    [{action_resource_id(), action_config()}].
on_get_channels(ConnResId) ->
    emqx_bridge_v2:get_channels_for_connector(ConnResId).

-spec on_get_channel_status(
    connector_resource_id(),
    action_resource_id(),
    connector_state()
) ->
    ?status_connected | ?status_disconnected.
on_get_channel_status(
    ConnResId,
    ActionResId,
    _ConnState = #{installed_actions := InstalledActions}
) when is_map_key(ActionResId, InstalledActions) ->
    ActionState = maps:get(ActionResId, InstalledActions),
    action_status(ConnResId, ActionResId, ActionState);
on_get_channel_status(_ConnResId, _ActionResId, _ConnState) ->
    ?status_disconnected.

-spec on_query(connector_resource_id(), query(), connector_state()) ->
    {ok, _Result} | {error, _Reason}.
on_query(
    _ConnResId, {ActionResId, Data}, #{installed_actions := InstalledActions} = _ConnState
) when
    is_map_key(ActionResId, InstalledActions)
->
    #{ActionResId := ActionState} = InstalledActions,
    run_aggregated_action([Data], ActionResId, ActionState);
on_query(
    _ConnResId,
    #insert_report{action_res_id = ActionResId, opts = Opts},
    #{installed_actions := InstalledActions} = _ConnState
) when
    is_map_key(ActionResId, InstalledActions)
->
    #{http := HTTPClientConfig} = maps:get(ActionResId, InstalledActions),
    insert_report_request(ActionResId, Opts, HTTPClientConfig);
on_query(_ConnResId, Query, _ConnState) ->
    {error, {unrecoverable_error, {invalid_query, Query}}}.

-spec on_batch_query(connector_resource_id(), [query()], connector_state()) ->
    {ok, _Result} | {error, _Reason}.
on_batch_query(_ConnResId, [{ActionResId, _} | _] = Batch0, #{installed_actions := InstalledActions}) when
    is_map_key(ActionResId, InstalledActions)
->
    #{ActionResId := ActionState} = InstalledActions,
    Batch = [Data || {_, Data} <- Batch0],
    run_aggregated_action(Batch, ActionResId, ActionState);
on_batch_query(_ConnResId, Batch, _ConnState) ->
    {error, {unrecoverable_error, {bad_batch, Batch}}}.

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% Used for debugging.
-spec insert_report(action_resource_id(), _Opts :: map()) -> {ok, map()} | {error, term()}.
insert_report(ActionResId, Opts) ->
    emqx_resource:simple_sync_query(
        ActionResId, #insert_report{action_res_id = ActionResId, opts = Opts}
    ).

%%------------------------------------------------------------------------------
%% `ecpool_worker' API
%%------------------------------------------------------------------------------

connect(Opts) ->
    ConnectStr = conn_str(Opts),
    %% Note: we don't use `emqx_secret:wrap/1` here because its return type is opaque, and
    %% dialyzer then complains that it's being fed to a function that doesn't expect
    %% something opaque...
    ConnectStrWrapped = fun() -> ConnectStr end,
    DriverOpts = proplists:get_value(driver_options, Opts, []),
    odbc:connect(ConnectStrWrapped, DriverOpts).

disconnect(ConnectionPid) ->
    odbc:disconnect(ConnectionPid).

health_check_connector(ConnResId) ->
    Res = emqx_resource_pool:health_check_workers(
        ConnResId,
        fun ?MODULE:do_health_check_connector/1,
        ?HC_TIMEOUT
    ),
    case Res of
        true ->
            ?status_connected;
        false ->
            ?status_disconnected
    end.

do_health_check_connector(ConnectionPid) ->
    case odbc:sql_query(ConnectionPid, "show schemas") of
        {selected, _, _} ->
            true;
        _ ->
            false
    end.

-spec stage_file(odbc_pool(), file:filename(), database(), schema(), stage(), action_name()) ->
    {ok, file:filename()} | {error, term()}.
stage_file(ODBCPool, Filename, Database, Schema, Stage, ActionName) ->
    Res = ecpool:pick_and_do(
        ODBCPool,
        {?MODULE, do_stage_file, [Filename, Database, Schema, Stage, ActionName]},
        %% Must be executed by the ecpool worker, which owns the ODBC connection.
        handover
    ),
    Context = #{
        filename => Filename,
        database => Database,
        schema => Schema,
        stage => Stage,
        pool => ODBCPool
    },
    handle_stage_file_result(Res, Context).

-spec do_stage_file(
    odbc:connection_reference(), file:filename(), database(), schema(), stage(), action_name()
) ->
    {ok, file:filename()} | {error, term()}.
do_stage_file(ConnPid, Filename, Database, Schema, Stage, ActionName) ->
    SQL = stage_file_sql(Filename, Database, Schema, Stage, ActionName),
    ?tp(debug, "snowflake_stage_file", #{sql => SQL, action => ActionName}),
    %% Should we also check if it actually succeeded by inspecting reportFiles?
    odbc:sql_query(ConnPid, SQL).

-spec handle_stage_file_result({selected, [string()], [tuple()]} | {error, term()}, map()) ->
    {ok, file:filename()} | {error, term()}.
handle_stage_file_result({selected, Headers0, Rows}, Context) ->
    #{filename := Filename} = Context,
    Headers = lists:map(fun emqx_utils_conv:bin/1, Headers0),
    ParsedRows = lists:map(fun(R) -> row_to_map(R, Headers) end, Rows),
    case ParsedRows of
        [#{<<"target">> := Target, <<"status">> := <<"UPLOADED">>}] ->
            ?tp(debug, "snowflake_stage_file_succeeded", Context#{
                result => ParsedRows
            }),
            ok = file:delete(Filename),
            {ok, Target};
        [#{<<"target">> := Target, <<"status">> := <<"SKIPPED">>}] ->
            ?tp(info, "snowflake_stage_file_skipped", Context#{
                result => ParsedRows
            }),
            ok = file:delete(Filename),
            {ok, Target};
        _ ->
            ?tp(warning, "snowflake_stage_bad_response", Context#{
                result => ParsedRows
            }),
            {error, {bad_response, ParsedRows}}
    end;
handle_stage_file_result({error, Reason} = Error, Context) ->
    ?tp(warning, "snowflake_stage_file_failed", Context#{
        reason => Reason
    }),
    Error.

%%------------------------------------------------------------------------------
%% `emqx_connector_aggreg_delivery' API
%%------------------------------------------------------------------------------

-spec init_transfer_state_and_container_opts(buffer(), transfer_opts()) ->
    {ok, transfer_state(), map()}.
init_transfer_state_and_container_opts(Buffer, Opts) ->
    #{
        container := #{type := ContainerType} = ContainerOpts,
        upload_options := #{
            action := ActionName,
            database := Database,
            schema := Schema,
            stage := Stage,
            odbc_pool := ODBCPool,
            http_pool := HTTPPool,
            http_client_config := HTTPClientConfig,
            max_block_size := MaxBlockSize,
            min_block_size := MinBlockSize,
            work_dir := WorkDir
        }
    } = Opts,
    BufferSeq = emqx_connector_aggreg_buffer_ctx:sequence(Buffer),
    BufferDT = emqx_connector_aggreg_buffer_ctx:datetime(Buffer, <<"unix">>),
    FilenameTemplate = emqx_template:parse(
        <<"${buffer_datetime}_${buffer_seq}_${seq_no}.${container_type}">>
    ),
    TransferState = #{
        action_name => ActionName,

        buffer_seq => BufferSeq,
        buffer_datetime => BufferDT,
        seq_no => 0,
        container_type => ContainerType,

        http_pool => HTTPPool,
        http_client_config => HTTPClientConfig,

        odbc_pool => ODBCPool,
        database => Database,
        schema => Schema,
        stage => Stage,
        filename_template => FilenameTemplate,
        filename => undefined,
        fd => undefined,
        work_dir => WorkDir,
        written => 0,
        staged_files => [],
        next_file => queue:new(),

        max_block_size => MaxBlockSize,
        min_block_size => MinBlockSize
    },
    {ok, TransferState, ContainerOpts}.

-spec process_append(iodata(), transfer_state()) ->
    transfer_state().
process_append(IOData, TransferState0) ->
    #{min_block_size := MinBlockSize} = TransferState0,
    Size = iolist_size(IOData),
    %% Open and write to file until minimum is reached
    TransferState1 = ensure_file(TransferState0),
    #{written := Written} = TransferState2 = append_to_file(IOData, Size, TransferState1),
    case Written >= MinBlockSize of
        true ->
            close_and_enqueue_file(TransferState2);
        false ->
            TransferState2
    end.

ensure_file(#{fd := undefined} = TransferState) ->
    #{
        buffer_datetime := BufferDT,
        buffer_seq := BufferSeq,
        container_type := ContainerType,
        filename_template := FilenameTemplate,
        seq_no := SeqNo,
        work_dir := WorkDir
    } = TransferState,
    Filename0 = emqx_template:render_strict(FilenameTemplate, #{
        buffer_datetime => BufferDT,
        buffer_seq => BufferSeq,
        seq_no => SeqNo,
        container_type => ContainerType
    }),
    Filename1 = filename:join([WorkDir, <<"tmp">>, Filename0]),
    Filename2 = filename:absname(Filename1),
    Filename = emqx_utils:safe_filename(Filename2),
    ok = filelib:ensure_dir(Filename),
    {ok, FD} = file:open(Filename, [write, binary]),
    TransferState#{
        filename := Filename,
        fd := FD
    };
ensure_file(TransferState) ->
    TransferState.

append_to_file(IOData, Size, TransferState) ->
    #{
        fd := FD,
        written := Written
    } = TransferState,
    %% Todo: handle errors?
    ok = file:write(FD, IOData),
    TransferState#{written := Written + Size}.

close_and_enqueue_file(TransferState0) ->
    #{
        fd := FD,
        filename := Filename,
        next_file := NextFile,
        seq_no := SeqNo,
        written := Written
    } = TransferState0,
    ok = file:close(FD),
    TransferState0#{
        next_file := queue:in({Filename, Written}, NextFile),
        filename := undefined,
        fd := undefined,
        seq_no := SeqNo + 1,
        written := 0
    }.

-spec process_write(transfer_state()) ->
    {ok, transfer_state()} | {error, term()}.
process_write(TransferState0) ->
    #{next_file := NextFile0} = TransferState0,
    case queue:out(NextFile0) of
        {{value, {Filename, Size}}, NextFile} ->
            ?tp(snowflake_will_stage_file, #{}),
            do_process_write(Filename, Size, TransferState0#{next_file := NextFile});
        {empty, _} ->
            {ok, TransferState0}
    end.

-spec do_process_write(file:filename(), non_neg_integer(), transfer_state()) ->
    {ok, transfer_state()} | {error, term()}.
do_process_write(Filename, Size, TransferState0) ->
    #{
        action_name := ActionName,
        odbc_pool := ODBCPool,
        database := Database,
        schema := Schema,
        stage := Stage,
        staged_files := StagedFiles0
    } = TransferState0,
    case stage_file(ODBCPool, Filename, Database, Schema, Stage, ActionName) of
        {ok, Target0} ->
            Target = filename:join(ActionName, Target0),
            StagedFile = #{path => Target, size => Size},
            StagedFiles = [StagedFile | StagedFiles0],
            TransferState = TransferState0#{staged_files := StagedFiles},
            process_write(TransferState);
        {error, Reason} ->
            %% TODO: retry?
            {error, Reason}
    end.

-spec process_complete(transfer_state()) ->
    {ok, term()}.
process_complete(TransferState0) ->
    #{written := Written0} = TransferState0,
    maybe
        %% Flush any left-over data
        {ok, TransferState} ?=
            case Written0 > 0 of
                true ->
                    ?tp("snowflake_flush_on_complete", #{}),
                    TransferState1 = close_and_enqueue_file(TransferState0),
                    process_write(TransferState1);
                false ->
                    {ok, TransferState0}
            end,
        #{
            http_pool := HTTPPool,
            http_client_config := HTTPClientConfig,
            staged_files := StagedFiles
        } = TransferState,
        case insert_files_request(StagedFiles, HTTPPool, HTTPClientConfig) of
            {ok, 200, _, Body} ->
                {ok, emqx_utils_json:decode(Body)};
            Res ->
                ?tp("snowflake_insert_files_request_failed", #{response => Res}),
                %% TODO: retry?
                exit({upload_failed, Res})
        end
    end.

-spec process_terminate(transfer_state()) -> ok.
process_terminate(_TransferState) ->
    %% todo: cleanup staged files?
    ok.

-spec process_format_status(transfer_state()) -> map().
process_format_status(TransferState) ->
    #{
        http_client_config := HTTPClientConfig,
        next_file := NextFile
    } = TransferState,
    TransferState#{
        http_client_config := HTTPClientConfig#{jwt_config := <<"...">>},
        next_file := queue:to_list(NextFile)
    }.

%%------------------------------------------------------------------------------
%% Internal fns
%%------------------------------------------------------------------------------

-spec create_action(
    connector_resource_id(), action_resource_id(), action_config(), connector_state()
) ->
    {ok, action_state()} | {error, term()}.
create_action(ConnResId, ActionResId, ActionConfig, ConnState) ->
    ok = emqx_connector_jwt:delete_jwt(?JWT_TABLE, ActionResId),
    maybe
        {ok, ActionState0} ?=
            start_aggregated_http_pool(ConnResId, ActionResId, ActionConfig, ConnState),
        _ = check_snowpipe_user_permission(ActionResId, ConnResId, ActionState0),
        start_aggregator(ConnResId, ActionResId, ActionConfig, ActionState0)
    end.

start_aggregated_http_pool(ConnResId, ActionResId, ActionConfig, ConnState) ->
    #{server := #{host := Host, port := Port}} = ConnState,
    #{
        parameters := #{
            database := Database,
            schema := Schema,
            pipe := Pipe,
            pipe_user := _,
            private_key := _,
            connect_timeout := ConnectTimeout,
            pool_size := PoolSize,
            max_retries := MaxRetries
        },
        resource_opts := #{request_ttl := RequestTTL}
    } = ActionConfig,
    PipeParts = lists:map(fun maybe_quote/1, [Database, Schema, Pipe]),
    PipePath0 = iolist_to_binary(lists:join($., PipeParts)),
    PipePath = uri_string:quote(PipePath0),
    PipePrefix = iolist_to_binary([
        <<"https://">>,
        Host,
        <<":">>,
        integer_to_binary(Port),
        <<"/v1/data/pipes/">>,
        PipePath
    ]),
    InserFilesPath = iolist_to_binary([
        PipePrefix,
        <<"/insertFiles">>
    ]),
    InserReportPath = iolist_to_binary([
        PipePrefix,
        <<"/insertReport">>
    ]),
    JWTConfig = jwt_config(ActionResId, ActionConfig, ConnState),
    PoolOpts =
        [
            {host, Host},
            {port, Port},
            {pool_type, random},
            {pool_size, PoolSize}
            | common_ehttpc_pool_opts(ActionConfig)
        ],
    allocate(ConnResId, ?aggregated_http_pool(ActionResId), ActionResId),
    case ehttpc_sup:start_pool(ActionResId, PoolOpts) of
        {ok, _} ->
            {ok, #{
                http => #{
                    jwt_config => JWTConfig,
                    insert_files_path => InserFilesPath,
                    insert_report_path => InserReportPath,
                    connect_timeout => ConnectTimeout,
                    max_retries => MaxRetries,
                    request_ttl => RequestTTL
                }
            }};
        {error, {already_started, _}} ->
            _ = ehttpc_sup:stop_pool(ActionResId),
            start_aggregated_http_pool(ConnResId, ActionResId, ActionConfig, ConnState);
        {error, Reason} ->
            {error, Reason}
    end.

start_aggregator(ConnResId, ActionResId, ActionConfig, ActionState0) ->
    #{
        bridge_name := Name,
        parameters := #{
            mode := ?aggregated = Mode,
            database := Database,
            schema := Schema,
            stage := Stage,
            aggregation := #{
                container := ContainerOpts,
                max_records := MaxRecords,
                time_interval := TimeInterval
            },
            max_block_size := MaxBlockSize,
            min_block_size := MinBlockSize
        }
    } = ActionConfig,
    #{http := HTTPClientConfig} = ActionState0,
    Type = ?ACTION_TYPE_AGGREG_BIN,
    AggregId = {Type, Name},
    WorkDir = work_dir(Type, Name),
    AggregOpts = #{
        max_records => MaxRecords,
        time_interval => TimeInterval,
        work_dir => WorkDir
    },
    TransferOpts = #{
        action => Name,
        action_res_id => ActionResId,
        odbc_pool => ConnResId,
        database => Database,
        schema => Schema,
        stage => Stage,
        http_pool => ActionResId,
        http_client_config => HTTPClientConfig,
        max_block_size => MaxBlockSize,
        min_block_size => MinBlockSize,
        work_dir => WorkDir
    },
    DeliveryOpts = #{
        callback_module => ?MODULE,
        container => ContainerOpts,
        upload_options => TransferOpts
    },
    allocate(ConnResId, ?aggregated_delivery_sup(ActionResId), AggregId),
    _ = ?AGGREG_SUP:delete_child(AggregId),
    maybe
        {ok, SupPid} ?=
            ?AGGREG_SUP:start_child(#{
                id => AggregId,
                start =>
                    {emqx_connector_aggreg_upload_sup, start_link, [
                        AggregId, AggregOpts, DeliveryOpts
                    ]},
                type => supervisor,
                restart => permanent
            }),
        {ok, ActionState0#{
            mode => Mode,
            aggreg_id => AggregId,
            supervisor => SupPid
        }}
    else
        {error, Reason} ->
            _ = ehttpc_sup:stop_pool(ActionResId),
            {error, Reason}
    end.

-spec destroy_action(connector_resource_id(), action_resource_id(), action_state()) -> ok.
destroy_action(ConnResId, ActionResId, _ActionState) ->
    aggregated_destroy_allocated_resources(ConnResId, ActionResId),
    ok = ensure_common_action_destroyed(ActionResId),
    ok.

ensure_common_action_destroyed(ActionResId) ->
    ok = ehttpc_sup:stop_pool(ActionResId),
    ok = emqx_connector_jwt:delete_jwt(?JWT_TABLE, ActionResId),
    ok.

run_aggregated_action(Batch, ActionResId, #{aggreg_id := AggregId}) ->
    Timestamp = erlang:system_time(second),
    emqx_trace:rendered_action_template(ActionResId, #{records => Batch}),
    case emqx_connector_aggregator:push_records(AggregId, Timestamp, Batch) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {unrecoverable_error, Reason}}
    end.

work_dir(Type, Name) ->
    filename:join([emqx:data_dir(), bridge, Type, Name]).

str(X) -> emqx_utils_conv:str(X).

conn_str(Opts) ->
    lists:concat(conn_str(Opts, [])).

conn_str([], Acc) ->
    lists:join(";", Acc);
conn_str([{dsn, DSN} | Opts], Acc) ->
    conn_str(Opts, ["dsn=" ++ str(DSN) | Acc]);
conn_str([{server, Server} | Opts], Acc) ->
    conn_str(Opts, ["server=" ++ str(Server) | Acc]);
conn_str([{private_key_path, Path} | Opts], Acc) ->
    conn_str(Opts, ["authenticator=SNOWFLAKE_JWT", "priv_key_file=" ++ str(Path) | Acc]);
conn_str([{private_key_password, Password} | Opts], Acc) ->
    conn_str(Opts, ["priv_key_file_pwd=" ++ str(emqx_secret:unwrap(Password)) | Acc]);
conn_str([{account, Account} | Opts], Acc) ->
    conn_str(Opts, ["account=" ++ str(Account) | Acc]);
conn_str([{username, Username} | Opts], Acc) ->
    conn_str(Opts, ["uid=" ++ str(Username) | Acc]);
conn_str([{password, Password} | Opts], Acc) ->
    conn_str(Opts, ["pwd=" ++ str(emqx_secret:unwrap(Password)) | Acc]);
conn_str([{proxy, none} | Opts], Acc) ->
    conn_str(Opts, Acc);
conn_str([{proxy, #{host := Host, port := Port}} | Opts], Acc) ->
    conn_str(Opts, ["proxy=" ++ str(Host) ++ ":" ++ str(Port) | Acc]);
conn_str([{_, _} | Opts], Acc) ->
    conn_str(Opts, Acc).

jwt_config(ActionResId, ActionConfig, ConnState) ->
    #{account := Account} = ConnState,
    #{
        parameters := #{
            private_key := PrivateKeyPEM,
            pipe_user := PipeUser
        } = Parameters
    } = ActionConfig,
    PrivateKeyPassword = maps:get(private_key_password, Parameters, undefined),
    Params = #{
        account => Account,
        private_key => PrivateKeyPEM,
        private_key_password => PrivateKeyPassword,
        pipe_user => PipeUser
    },
    emqx_bridge_snowflake_lib:jwt_config(ActionResId, Params).

insert_files_request(StagedFiles, HTTPPool, HTTPClientConfig) ->
    #{
        jwt_config := JWTConfig,
        insert_files_path := InserFilesPath,
        request_ttl := RequestTTL,
        max_retries := MaxRetries
    } = HTTPClientConfig,
    JWTToken = emqx_connector_jwt:ensure_jwt(JWTConfig),
    AuthnHeader = [<<"BEARER ">>, JWTToken],
    Headers = http_headers(AuthnHeader),
    Body = emqx_utils_json:encode(#{files => StagedFiles}),
    %% TODO: generate unique request id
    Req = {InserFilesPath, Headers, Body},
    ?tp(debug, "snowflake_stage_insert_files_request", #{
        action_res_id => HTTPPool,
        staged_files => StagedFiles
    }),
    ?MODULE:do_insert_files_request(HTTPPool, Req, RequestTTL, MaxRetries).

%% Exposed for mocking
do_insert_files_request(HTTPPool, Req, RequestTTL, MaxRetries) ->
    ehttpc:request(HTTPPool, post, Req, RequestTTL, MaxRetries).

insert_report_request(HTTPPool, Opts, HTTPClientConfig) ->
    #{
        jwt_config := JWTConfig,
        insert_report_path := InsertReportPath0,
        request_ttl := RequestTTL,
        max_retries := MaxRetries
    } = HTTPClientConfig,
    JWTToken = emqx_connector_jwt:ensure_jwt(JWTConfig),
    AuthnHeader = [<<"BEARER ">>, JWTToken],
    Headers = http_headers(AuthnHeader),
    QString = insert_report_query_string(Opts),
    InsertReportPath =
        case QString of
            <<>> ->
                InsertReportPath0;
            _ ->
                <<InsertReportPath0/binary, "?", QString/binary>>
        end,
    ?SLOG(debug, #{
        msg => "snowflake_insert_report_request",
        path => InsertReportPath,
        pool => HTTPPool
    }),
    Req = {InsertReportPath, Headers},
    Response = ?MODULE:do_insert_report_request(HTTPPool, Req, RequestTTL, MaxRetries),
    case Response of
        {ok, 200, _Headers, Body0} ->
            Body = emqx_utils_json:decode(Body0),
            {ok, Body};
        _ ->
            {error, Response}
    end.

insert_report_query_string(Opts0) ->
    Opts1 = maps:with([begin_mark, request_id], Opts0),
    Opts2 = maps:filter(fun(_K, V) -> is_binary(V) end, Opts1),
    Opts3 = emqx_utils_maps:rename(begin_mark, <<"beginMark">>, Opts2),
    Opts = emqx_utils_maps:rename(request_id, <<"requestId">>, Opts3),
    emqx_utils_conv:bin(uri_string:compose_query(maps:to_list(Opts))).

%% Internal export only for mocking
do_insert_report_request(HTTPPool, Req, RequestTTL, MaxRetries) ->
    ehttpc:request(HTTPPool, get, Req, RequestTTL, MaxRetries).

http_headers(AuthnHeader) ->
    [
        {<<"X-Snowflake-Authorization-Token-Type">>, <<"KEYPAIR_JWT">>},
        {<<"Content-Type">>, <<"application/json">>},
        {<<"Authorization">>, AuthnHeader}
    ].

row_to_map(Row0, Headers) ->
    Row1 = tuple_to_list(Row0),
    Row2 = lists:map(fun emqx_utils_conv:bin/1, Row1),
    Row = lists:zip(Headers, Row2),
    maps:from_list(Row).

action_status(ConnResId, ActionResId, ActionState) ->
    #{
        aggreg_id := AggregId,
        http := #{connect_timeout := ConnectTimeout}
    } = ActionState,
    %% NOTE: This will effectively trigger uploads of buffers yet to be uploaded.
    Timestamp = erlang:system_time(second),
    ok = emqx_connector_aggregator:tick(AggregId, Timestamp),
    ok = check_aggreg_upload_errors(AggregId),
    case http_pool_workers_healthy(ActionResId, ConnectTimeout) of
        ok ->
            ok = check_snowpipe_user_permission(ActionResId, ConnResId, ActionState),
            ?status_connected;
        {error, Reason} ->
            {?status_disconnected, Reason}
    end.

stage_file_sql(Filename, Database, Schema, Stage, ActionName) ->
    SQL0 = iolist_to_binary([
        <<"PUT file://">>,
        %% TODO: use action as directory name on stage?
        Filename,
        <<" @">>,
        maybe_quote(Database),
        <<".">>,
        maybe_quote(Schema),
        <<".">>,
        maybe_quote(Stage),
        <<"/">>,
        ActionName
    ]),
    binary_to_list(SQL0).

http_pool_workers_healthy(HTTPPool, Timeout) ->
    emqx_bridge_snowflake_lib:http_pool_workers_healthy(HTTPPool, Timeout).

%% https://docs.snowflake.com/en/sql-reference/identifiers-syntax
needs_quoting(Identifier) ->
    nomatch =:= re:run(Identifier, <<"^[A-Za-z_][A-Za-z_0-9$]*$">>, [{capture, none}]).

maybe_quote(Identifier) ->
    case needs_quoting(Identifier) of
        true ->
            emqx_utils_sql:escape_snowflake(Identifier);
        false ->
            Identifier
    end.

check_aggreg_upload_errors(AggregId) ->
    case emqx_connector_aggregator:take_error(AggregId) of
        [Error] ->
            ?tp("snowflake_check_aggreg_upload_error_found", #{error => Error}),
            %% TODO
            %% This approach means that, for example, 3 upload failures will cause
            %% the channel to be marked as unhealthy for 3 consecutive health checks.
            ErrorMessage = emqx_utils:format(Error),
            throw({unhealthy_target, ErrorMessage});
        [] ->
            ok
    end.

check_snowpipe_user_permission(HTTPPool, ODBCPool, ActionState) ->
    #{http := HTTPClientConfig} = ActionState,
    RequestId = list_to_binary(uuid:uuid_to_string(uuid:get_v4())),
    Opts = #{request_id => RequestId},
    case insert_report_request(HTTPPool, Opts, HTTPClientConfig) of
        {ok, _} ->
            ok;
        {error, {ok, 401, _, Body0}} ->
            Body =
                case emqx_utils_json:safe_decode(Body0) of
                    {ok, JSON} -> JSON;
                    {error, _} -> Body0
                end,
            FailureDetails = try_get_jwt_failure_details(ODBCPool, HTTPPool, Body),
            ?SLOG(warning, FailureDetails#{
                pool => HTTPPool,
                request_id => RequestId,
                msg => "snowflake_check_snowpipe_user_permission_error",
                body => Body
            }),
            Msg = <<
                "Configured pipe user does not have permissions to operate on pipe,"
                " or does not exist. Please check your configuration."
            >>,
            throw({unhealthy_target, Msg});
        {error, {ok, StatusCode, _}} ->
            Msg = iolist_to_binary([
                <<"Error checking if configured snowpipe user has permissions.">>,
                <<" HTTP Status Code: ">>,
                integer_to_binary(StatusCode)
            ]),
            %% Not marking it as unhealthy because it could be spurious
            throw(Msg);
        {error, {ok, StatusCode, _, Body}} ->
            Msg = iolist_to_binary([
                <<"Error checking if configured snowpipe user has permissions.">>,
                <<" HTTP Status Code: ">>,
                integer_to_binary(StatusCode),
                <<"; Body: ">>,
                Body
            ]),
            %% Not marking it as unhealthy because it could be spurious
            throw(Msg)
    end.

try_get_jwt_failure_details(ODBCPool, ActionResId, RespBody) ->
    maybe
        #{<<"message">> := Msg} ?= RespBody,
        {ok, RequestId} ?= get_jwt_error_request_id(Msg),
        {selected, [_ColHeader], [{Val}]} ?= get_login_failure_details(ODBCPool, RequestId),
        true ?= is_list(Val) orelse {error, {not_string, Val}},
        {ok, Data} ?= emqx_utils_json:safe_decode(Val),
        #{failure_details => Data}
    else
        Err ->
            ?SLOG(debug, #{
                msg => "snowflake_action_get_jwt_failure_details_err",
                action_res_id => ActionResId,
                reason => Err
            }),
            %% When role doesn't have MONITOR on account, the command returns:
            %% SQL compilation error:\nUnknown function SYSTEM$GET_LOGIN_FAILURE_DETAILS
            %% SQLSTATE IS: 42601
            Hint = <<
                "To get more details about the login failure, log into your",
                " Snowflake account with an admin role that has the MONITOR privilege",
                " on the account, and check the output of",
                " SYSTEM$GET_LOGIN_FAILURE_DETAILS on logged request id."
            >>,
            #{failure_details => undefined, hint => Hint}
    end.

%% Even if we provide a request id for the HTTP call, snowflake decides to use its own
%% request id when returning JWT errors...
get_jwt_error_request_id(Msg) when is_binary(Msg) ->
    %% ece3379e-6715-4d48-adeb-d5507d05e3e2
    HexChar = <<"[0-9a-fA-F]">>,
    UUIDRE = iolist_to_binary([
        HexChar,
        <<"{8}-">>,
        HexChar,
        <<"{4}-">>,
        HexChar,
        <<"{4}-">>,
        HexChar,
        <<"{4}-">>,
        HexChar,
        <<"{12}">>
    ]),
    RE = <<"\\[(", UUIDRE/binary, ")\\]">>,
    case re:run(Msg, RE, [{capture, all_but_first, binary}]) of
        {match, [UUID]} ->
            {ok, UUID};
        _ ->
            {error, <<"couldn't obtain jwt request id from error message">>}
    end;
get_jwt_error_request_id(_) ->
    {error, <<"couldn't obtain jwt request id from error message">>}.

get_login_failure_details(ODBCPool, RequestId) ->
    try
        ecpool:pick_and_do(
            ODBCPool,
            {?MODULE, do_get_login_failure_details, [RequestId]},
            %% Must be executed by the ecpool worker, which owns the ODBC connection.
            handover
        )
    catch
        K:E:Stacktrace ->
            {error, #{kind => K, reason => E, stacktrace => Stacktrace}}
    end.

do_get_login_failure_details(ConnPid, RequestId) ->
    SQL0 = iolist_to_binary([
        <<"select SYSTEM$GET_LOGIN_FAILURE_DETAILS('">>,
        RequestId,
        <<"')">>
    ]),
    SQL = binary_to_list(SQL0),
    Timeout = 5_000,
    odbc:sql_query(ConnPid, SQL, Timeout).

mk_odbc_authn_opt(#{private_key_path := <<Path/binary>>} = ConnConfig) ->
    Password = maps:get(private_key_password, ConnConfig, undefined),
    lists:flatten([
        {private_key_path, Path},
        [{private_key_password, Password} || Password /= undefined]
    ]);
mk_odbc_authn_opt(#{password := Password}) ->
    [{password, Password}];
mk_odbc_authn_opt(_ConnConfig) ->
    %% Users can place password in `/etc/odbc.ini`.
    [].

common_ehttpc_pool_opts(ActionConfig) ->
    #{
        parameters := #{
            connect_timeout := ConnectTimeout,
            pipelining := Pipelining,
            max_inactive := MaxInactive,
            proxy := ProxyConfig
        }
    } = ActionConfig,
    Params = #{
        connect_timeout => ConnectTimeout,
        pipelining => Pipelining,
        max_inactive => MaxInactive,
        proxy => ProxyConfig
    },
    emqx_bridge_snowflake_lib:common_ehttpc_pool_opts(Params).

aggregated_destroy_allocated_resources(ConnResId) ->
    aggregated_destroy_allocated_resources(ConnResId, _ActionResId = '_').

aggregated_destroy_allocated_resources(ConnResId, ActionResId) ->
    maps:foreach(
        fun
            (?aggregated_http_pool(Id) = Key, Pool) when
                ActionResId == '_' orelse Id == ActionResId
            ->
                _ = ehttpc_sup:stop_pool(Pool),
                deallocate(ConnResId, Key),
                ok;
            (?aggregated_delivery_sup(Id) = Key, AggregId) when
                ActionResId == '_' orelse Id == ActionResId
            ->
                _ = ?AGGREG_SUP:delete_child(AggregId),
                deallocate(ConnResId, Key),
                ok;
            (_, _) ->
                ok
        end,
        emqx_resource:get_allocated_resources(ConnResId)
    ).

allocate(ConnResId, Key, Value) ->
    ok = emqx_resource:allocate_resource(ConnResId, ?MODULE, Key, Value).

deallocate(ConnResId, Key) ->
    ok = emqx_resource:deallocate_resource(ConnResId, Key).

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

needs_quoting_test_() ->
    PositiveCases = [
        <<"with spaece">>,
        <<"1_number_in_beginning">>,
        <<"contains_açéntõ">>,
        <<"with-hyphen">>,
        <<"">>
    ],
    NegativeCases = [
        <<"testdatabase">>,
        <<"TESTDATABASE">>,
        <<"TestDatabase">>,
        <<"with_underscore">>,
        <<"with_underscore_10">>
    ],
    Positive = lists:map(fun(Id) -> {Id, ?_assert(needs_quoting(Id))} end, PositiveCases),
    Negative = lists:map(fun(Id) -> {Id, ?_assertNot(needs_quoting(Id))} end, NegativeCases),
    Positive ++ Negative.
-endif.
