%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_mgmt_api_data_backup_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(NODE1_PORT, 18085).
-define(NODE2_PORT, 18086).
-define(NODE3_PORT, 18087).
-define(api_base_url(_Port_), ("http://127.0.0.1:" ++ (integer_to_list(_Port_)))).

-define(UPLOAD_EE_BACKUP, "emqx-export-upload-ee.tar.gz").
-define(UPLOAD_CE_BACKUP, "emqx-export-upload-ce.tar.gz").
-define(BAD_UPLOAD_BACKUP, "emqx-export-bad-upload.tar.gz").
-define(BAD_IMPORT_BACKUP, "emqx-export-bad-file.tar.gz").
-define(backup_path(_Config_, _BackupName_),
    filename:join(?config(data_dir, _Config_), _BackupName_)
).
-define(ON(NODE, BODY), erpc:call(NODE, fun() -> BODY end)).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Config.

end_per_suite(_) ->
    ok.

init_per_testcase(TC, Config) when
    TC =:= t_upload_ee_backup;
    TC =:= t_import_ee_backup
->
    case emqx_release:edition() of
        ee -> do_init_per_testcase(TC, Config);
        ce -> Config
    end;
init_per_testcase(TC, Config) ->
    do_init_per_testcase(TC, Config).

end_per_testcase(_TC, Config) ->
    case ?config(cluster, Config) of
        undefined -> ok;
        Cluster -> emqx_cth_cluster:stop(Cluster)
    end.

t_export_backup(Config) ->
    Auth = ?config(auth, Config),
    export_test(?NODE1_PORT, Auth),
    export_test(?NODE2_PORT, Auth),
    export_test(?NODE3_PORT, Auth).

t_delete_backup(Config) ->
    test_file_op(delete, Config).

t_get_backup(Config) ->
    test_file_op(get, Config).

t_list_backups(Config) ->
    Auth = ?config(auth, Config),

    [{ok, _} = export_backup(?NODE1_PORT, Auth) || _ <- lists:seq(1, 10)],
    [{ok, _} = export_backup(?NODE2_PORT, Auth) || _ <- lists:seq(1, 10)],

    {ok, RespBody} = list_backups(?NODE1_PORT, Auth, <<"1">>, <<"100">>),
    #{<<"data">> := Data, <<"meta">> := #{<<"count">> := 20, <<"hasnext">> := false}} = emqx_utils_json:decode(
        RespBody
    ),
    ?assertEqual(20, length(Data)),

    {ok, EmptyRespBody} = list_backups(?NODE2_PORT, Auth, <<"2">>, <<"100">>),
    #{<<"data">> := EmptyData, <<"meta">> := #{<<"count">> := 20, <<"hasnext">> := false}} = emqx_utils_json:decode(
        EmptyRespBody
    ),
    ?assertEqual(0, length(EmptyData)),

    {ok, RespBodyP1} = list_backups(?NODE3_PORT, Auth, <<"1">>, <<"10">>),
    {ok, RespBodyP2} = list_backups(?NODE3_PORT, Auth, <<"2">>, <<"10">>),
    {ok, RespBodyP3} = list_backups(?NODE3_PORT, Auth, <<"3">>, <<"10">>),

    #{<<"data">> := DataP1, <<"meta">> := #{<<"count">> := 20, <<"hasnext">> := true}} = emqx_utils_json:decode(
        RespBodyP1
    ),
    ?assertEqual(10, length(DataP1)),
    #{<<"data">> := DataP2, <<"meta">> := #{<<"count">> := 20, <<"hasnext">> := false}} = emqx_utils_json:decode(
        RespBodyP2
    ),
    ?assertEqual(10, length(DataP2)),
    #{<<"data">> := DataP3, <<"meta">> := #{<<"count">> := 20, <<"hasnext">> := false}} = emqx_utils_json:decode(
        RespBodyP3
    ),
    ?assertEqual(0, length(DataP3)),

    ?assertEqual(Data, DataP1 ++ DataP2).

t_upload_ce_backup(Config) ->
    upload_backup_test(Config, ?UPLOAD_CE_BACKUP).

t_upload_ee_backup(Config) ->
    case emqx_release:edition() of
        ee -> upload_backup_test(Config, ?UPLOAD_EE_BACKUP);
        ce -> ok
    end.

t_import_ce_backup(Config) ->
    import_backup_test(Config, ?UPLOAD_CE_BACKUP).

t_import_ee_backup(Config) ->
    case emqx_release:edition() of
        ee -> import_backup_test(Config, ?UPLOAD_EE_BACKUP);
        ce -> ok
    end.

%% Simple smoke test for cloud export API (export with scoped table set names and root
%% keys).
t_export_cloud(Config) ->
    Auth = ?config(auth, Config),
    Resp = export_cloud_backup(?NODE1_PORT, Auth),
    {200, #{<<"filename">> := Filepath}} = Resp,
    {ok, _} = import_backup(?NODE1_PORT, Auth, Filepath),
    ok.

%% Simple smoke test for exporting a subset of config root keys and tables via the CLI.
t_export_cloud_ctl(Config) ->
    [N1 | _] = ?config(cluster, Config),
    %% Need to explicitly load the commands because they are loaded by `emqx_machine'...
    ?ON(N1, emqx_mgmt_cli:load()),
    ok = ?ON(N1, meck:new(emqx_ctl, [no_link, passthrough])),
    RootKeys = [
        <<"connectors">>,
        <<"actions">>,
        <<"sources">>,
        <<"rule_engine">>,
        <<"schema_registry">>
    ],
    TableSets = [
        <<"banned">>,
        <<"builtin_authn">>,
        <<"builtin_authz">>
    ],
    RootKeysArg = lists:join($,, RootKeys),
    TableSetsArg = lists:join($,, TableSets),
    ?ON(
        N1,
        emqx_ctl:run_command([
            "data", "export", "--root-keys", RootKeysArg, "--table-sets", TableSetsArg
        ])
    ),
    {ok, [BackupFile]} = ?ON(N1, file:list_dir(filename:join([emqx:data_dir(), "backup"]))),
    ?ON(N1, emqx_ctl:run_command(["data", "import", BackupFile])),
    History = ?ON(N1, meck:history(emqx_ctl)),
    ?ON(N1, meck:unload(emqx_ctl)),
    OutputMsgs = [Fmt || {_Pid, {emqx_ctl, print, [Fmt | _]}, _Res} <- History],
    ?assertMatch(
        [_],
        [1 || "Data has been successfully exported" ++ _ <- OutputMsgs],
        #{output => OutputMsgs}
    ),
    ?assertMatch(
        [_],
        [1 || "Data has been imported successfully" ++ _ <- OutputMsgs],
        #{output => OutputMsgs}
    ),
    ok.

%% Checks returned error when one or more invalid table set names are given to the export
%% request.
t_export_bad_table_sets(Config) ->
    Auth = ?config(auth, Config),
    Body = #{<<"table_sets">> => [<<"foo">>, <<"bar">>, <<"foo">>]},
    ?assertMatch(
        {400, #{<<"message">> := <<"Invalid table sets: bar, foo">>}},
        export_backup2(?NODE1_PORT, Auth, Body)
    ),
    ok.

%% Checks returned error when one or more invalid root config keys are given to the export
%% request.
t_export_bad_root_keys(Config) ->
    Auth = ?config(auth, Config),
    Body = #{<<"root_keys">> => [<<"foo">>, <<"bar">>, <<"foo">>]},
    ?assertMatch(
        {400, #{<<"message">> := <<"Invalid root keys: bar, foo">>}},
        export_backup2(?NODE1_PORT, Auth, Body)
    ),
    ok.

%% Checks that we import schema registry serdes before schema validations / message
%% transformations.
%% Note: this test cannot reproduce the issue reliably even before the fix that introduced
%% it.  It serves just as a canary for regressions, if it ever manages to catch it.
t_schema_registry_import_order(Config) ->
    [N1 | _] = ?config(cluster, Config),
    Auth = ?config(auth, Config),
    SerdeName = <<"test">>,
    CreateParams = emqx_schema_registry_SUITE:schema_params(avro),
    MTName = <<"mt">>,
    PayloadSerde = #{
        <<"type">> => <<"avro">>,
        <<"schema">> => SerdeName
    },
    Operation = emqx_message_transformation_http_api_SUITE:operation(
        <<"payload.name">>, <<"concat(['hello'])">>
    ),
    Transformation = emqx_message_transformation_http_api_SUITE:transformation(
        MTName, [Operation], #{
            <<"payload_decoder">> => PayloadSerde,
            <<"payload_encoder">> => PayloadSerde
        }
    ),
    SVName = <<"sv">>,
    Check = emqx_schema_validation_http_api_SUITE:schema_check(json, SerdeName),
    Validation = emqx_schema_validation_http_api_SUITE:validation(SVName, [Check]),

    ?ON(N1, begin
        ok = emqx_schema_registry:add_schema(SerdeName, CreateParams),
        {ok, _} = emqx_message_transformation:insert(Transformation),
        {ok, _} = emqx_schema_validation:insert(Validation),
        ok
    end),
    ExportBody = #{},
    {200, #{<<"filename">> := Filepath}} = export_backup2(?NODE1_PORT, Auth, ExportBody),
    %% Remove schema so it's absent when importing stuff back
    ?ON(N1, begin
        {ok, _} = emqx_message_transformation:delete(MTName),
        {ok, _} = emqx_schema_validation:delete(SVName),
        ok = emqx_schema_registry:delete_schema(SerdeName),
        ok
    end),
    {ok, _} = import_backup(?NODE1_PORT, Auth, Filepath),
    ok.

t_exhook_backup(Config) ->
    [N1 | _] = ?config(cluster, Config),
    Auth = ?config(auth, Config),
    Name = <<"myhook">>,
    ExhookConf = #{
        <<"name">> => Name,
        <<"url">> => <<"http://127.0.0.1">>
    },
    {ok, _} = ?ON(N1, emqx_exhook_mgr:update_config([exhook, servers], {add, ExhookConf})),
    ExportBody = #{},
    {200, #{<<"filename">> := Filepath}} = export_backup2(?NODE1_PORT, Auth, ExportBody),
    {ok, _} = ?ON(N1, emqx_exhook_mgr:update_config([exhook, servers], {delete, Name})),
    %% Need to explicitly load the commands because they are loaded by `emqx_machine'...
    ?ON(N1, emqx_mgmt_cli:load()),
    ?ON(N1, emqx_ctl:run_command(["data", "import", Filepath])),
    ok.

do_init_per_testcase(TC, Config) ->
    Cluster = [Core1, _Core2, Repl] = cluster(TC, Config),
    Auth = auth_header(Core1),
    ok = wait_for_auth_replication(Repl),
    [{auth, Auth}, {cluster, Cluster} | Config].

test_file_op(Method, Config) ->
    Auth = ?config(auth, Config),

    {ok, Node1Resp} = export_backup(?NODE1_PORT, Auth),
    {ok, Node2Resp} = export_backup(?NODE2_PORT, Auth),
    {ok, Node3Resp} = export_backup(?NODE3_PORT, Auth),

    ParsedResps = [emqx_utils_json:decode(R) || R <- [Node1Resp, Node2Resp, Node3Resp]],

    [Node1Parsed, Node2Parsed, Node3Parsed] = ParsedResps,

    %% node param is not set in Query, expect get/delete the backup on the local node
    F1 = fun() ->
        backup_file_op(Method, ?NODE1_PORT, Auth, maps:get(<<"filename">>, Node1Parsed), [])
    end,
    ?assertMatch({ok, _}, F1()),
    assert_second_call(Method, F1()),

    %% Node 2 must get/delete the backup on Node 3 via rpc
    F2 = fun() ->
        backup_file_op(
            Method,
            ?NODE2_PORT,
            Auth,
            maps:get(<<"filename">>, Node3Parsed),
            [{<<"node">>, maps:get(<<"node">>, Node3Parsed)}],
            #{return_all => true}
        )
    end,
    Res2 = F2(),
    Code2 =
        case Method of
            get -> 200;
            delete -> 204
        end,
    ?assertMatch({ok, {{_, Code2, _}, _, _}}, Res2),
    {ok, {{_, Code2, _}, Headers2List, _}} = Res2,
    case Method of
        get ->
            ?assertMatch(
                #{"content-type" := "application/octet-stream"}, maps:from_list(Headers2List)
            );
        _ ->
            ok
    end,
    assert_second_call(Method, F2()),

    %% The same as above but nodes are switched
    F3 = fun() ->
        backup_file_op(
            Method,
            ?NODE3_PORT,
            Auth,
            maps:get(<<"filename">>, Node2Parsed),
            [{<<"node">>, maps:get(<<"node">>, Node2Parsed)}]
        )
    end,
    ?assertMatch({ok, _}, F3()),
    assert_second_call(Method, F3()).

export_test(NodeApiPort, Auth) ->
    {ok, RespBody} = export_backup(NodeApiPort, Auth),
    #{
        <<"created_at">> := _,
        <<"created_at_sec">> := CreatedSec,
        <<"filename">> := _,
        <<"node">> := _,
        <<"size">> := Size
    } = emqx_utils_json:decode(RespBody),
    ?assert(is_integer(Size)),
    ?assert(is_integer(CreatedSec) andalso CreatedSec > 0).

upload_backup_test(Config, BackupName) ->
    Auth = ?config(auth, Config),
    UploadFile = ?backup_path(Config, BackupName),
    BadImportFile = ?backup_path(Config, ?BAD_IMPORT_BACKUP),
    BadUploadFile = ?backup_path(Config, ?BAD_UPLOAD_BACKUP),

    ?assertEqual(ok, upload_backup(?NODE3_PORT, Auth, UploadFile)),
    %% This file was specially forged to pass upload validation bat fail on import
    ?assertEqual(ok, upload_backup(?NODE2_PORT, Auth, BadImportFile)),
    ?assertEqual({error, bad_request}, upload_backup(?NODE1_PORT, Auth, BadUploadFile)),
    %% Invalid file must not be kept
    ?assertMatch(
        {error, {_, 404, _}}, backup_file_op(get, ?NODE1_PORT, Auth, ?BAD_UPLOAD_BACKUP, [])
    ).

import_backup_test(Config, BackupName) ->
    Auth = ?config(auth, Config),
    UploadFile = ?backup_path(Config, BackupName),
    BadImportFile = ?backup_path(Config, ?BAD_IMPORT_BACKUP),

    ?assertEqual(ok, upload_backup(?NODE3_PORT, Auth, UploadFile)),

    %% This file was specially forged to pass upload validation bat fail on import
    ?assertEqual(ok, upload_backup(?NODE2_PORT, Auth, BadImportFile)),

    %% Replicant node must be able to import the file by doing rpc to a core node
    ?assertMatch({ok, _}, import_backup(?NODE3_PORT, Auth, BackupName)),

    [N1, N2, N3] = ?config(cluster, Config),

    ?assertMatch({ok, _}, import_backup(?NODE3_PORT, Auth, BackupName)),

    ?assertMatch({ok, _}, import_backup(?NODE1_PORT, Auth, BackupName, N3)),
    %% Now this node must also have the file locally
    ?assertMatch({ok, _}, import_backup(?NODE1_PORT, Auth, BackupName, N1)),

    ?assertMatch({error, {_, 400, _}}, import_backup(?NODE2_PORT, Auth, ?BAD_IMPORT_BACKUP, N2)).

assert_second_call(get, Res) ->
    ?assertMatch({ok, _}, Res);
assert_second_call(delete, Res) ->
    case Res of
        {error, {_, 404, _}} ->
            ok;
        {error, {{_, 404, _}, _, _}} ->
            ok;
        _ ->
            ct:fail("unexpected result: ~p", [Res])
    end.

export_cloud_backup(NodeApiPort, Auth) ->
    Body = #{
        <<"table_sets">> => [
            <<"banned">>,
            <<"builtin_authn">>,
            <<"builtin_authz">>
        ],
        <<"root_keys">> => [
            <<"connectors">>,
            <<"actions">>,
            <<"sources">>,
            <<"rule_engine">>,
            <<"schema_registry">>
        ]
    },
    export_backup2(NodeApiPort, Auth, Body).

export_backup(NodeApiPort, Auth) ->
    Path = ["data", "export"],
    request(post, NodeApiPort, Path, _Body = #{}, Auth).

export_backup2(NodeApiPort, Auth, Body) ->
    Path = emqx_mgmt_api_test_util:api_path(?api_base_url(NodeApiPort), ["data", "export"]),
    emqx_mgmt_api_test_util:simple_request(post, Path, Body, Auth).

import_backup(NodeApiPort, Auth, BackupName) ->
    import_backup(NodeApiPort, Auth, BackupName, undefined).

import_backup(NodeApiPort, Auth, BackupName, Node) ->
    Path = ["data", "import"],
    Body = #{<<"filename">> => unicode:characters_to_binary(BackupName)},
    Body1 =
        case Node of
            undefined -> Body;
            _ -> Body#{<<"node">> => Node}
        end,
    request(post, NodeApiPort, Path, Body1, Auth).

list_backups(NodeApiPort, Auth, Page, Limit) ->
    Path = ["data", "files"],
    request(get, NodeApiPort, Path, [{<<"page">>, Page}, {<<"limit">>, Limit}], [], Auth).

backup_file_op(Method, NodeApiPort, Auth, BackupName, QueryList) ->
    backup_file_op(Method, NodeApiPort, Auth, BackupName, QueryList, _Opts = #{}).

backup_file_op(Method, NodeApiPort, Auth, BackupName, QueryList, Opts) ->
    Path = ["data", "files", BackupName],
    request(Method, NodeApiPort, Path, QueryList, [], Auth, Opts).

upload_backup(NodeApiPort, Auth, BackupFilePath) ->
    Path = emqx_mgmt_api_test_util:api_path(?api_base_url(NodeApiPort), ["data", "files"]),
    Res = emqx_mgmt_api_test_util:upload_request(
        Path,
        BackupFilePath,
        "filename",
        <<"application/octet-stream">>,
        [],
        Auth
    ),
    case Res of
        {ok, {{"HTTP/1.1", 204, _}, _Headers, _}} ->
            ok;
        {ok, {{"HTTP/1.1", 400, _}, _Headers, _} = Resp} ->
            ct:pal("Backup upload failed: ~p", [Resp]),
            {error, bad_request};
        Err ->
            Err
    end.

request(Method, NodePort, PathParts, Auth) ->
    request(Method, NodePort, PathParts, [], [], Auth).

request(Method, NodePort, PathParts, Body, Auth) ->
    request(Method, NodePort, PathParts, [], Body, Auth).

request(Method, NodePort, PathParts, QueryList, Body, Auth) ->
    request(Method, NodePort, PathParts, QueryList, Body, Auth, _Opts = #{}).

request(Method, NodePort, PathParts, QueryList, Body, Auth, Opts) ->
    Path = emqx_mgmt_api_test_util:api_path(?api_base_url(NodePort), PathParts),
    Query = unicode:characters_to_list(uri_string:compose_query(QueryList)),
    emqx_mgmt_api_test_util:request_api(Method, Path, Query, Auth, Body, Opts).

cluster(TC, Config) ->
    Nodes = emqx_cth_cluster:start(
        [
            {node_name(TC, core, 1), #{role => core, apps => apps_spec(18085, TC)}},
            {node_name(TC, core, 2), #{role => core, apps => apps_spec(18086, TC)}},
            {node_name(TC, replicant, 1), #{role => replicant, apps => apps_spec(18087, TC)}}
        ],
        #{
            work_dir => emqx_cth_suite:work_dir(TC, Config),
            start_apps_timeout => 60_000
        }
    ),
    Nodes.

node_name(TC, Role, N) ->
    NameBin = io_lib:format("api_data_backup_~s_~s~b", [TC, Role, N]),
    binary_to_atom(iolist_to_binary(NameBin)).

auth_header(Node) ->
    {ok, API} = erpc:call(Node, emqx_common_test_http, create_default_app, []),
    emqx_common_test_http:auth_header(API).

wait_for_auth_replication(ReplNode) ->
    wait_for_auth_replication(ReplNode, 100).

wait_for_auth_replication(ReplNode, 0) ->
    {error, {ReplNode, auth_not_ready}};
wait_for_auth_replication(ReplNode, Retries) ->
    try
        {_Header, _Val} = erpc:call(ReplNode, emqx_common_test_http, default_auth_header, []),
        ok
    catch
        _:_ ->
            timer:sleep(1),
            wait_for_auth_replication(ReplNode, Retries - 1)
    end.

apps_spec(APIPort, TC) ->
    common_apps_spec() ++
        app_spec_dashboard(APIPort) ++
        test_case_specific_apps_spec(TC).

common_apps_spec() ->
    [
        emqx,
        emqx_conf,
        emqx_management
    ].

app_spec_dashboard(APIPort) ->
    [
        {emqx_dashboard, #{
            config =>
                #{
                    dashboard =>
                        #{
                            listeners =>
                                #{
                                    http =>
                                        #{bind => APIPort}
                                },
                            default_username => "",
                            default_password => ""
                        }
                }
        }}
    ].

test_case_specific_apps_spec(TC) when
    TC =:= t_upload_ee_backup;
    TC =:= t_import_ee_backup;
    TC =:= t_upload_ce_backup;
    TC =:= t_import_ce_backup
->
    [
        emqx_auth,
        emqx_auth_http,
        emqx_auth_jwt,
        emqx_auth_mnesia,
        emqx_rule_engine,
        emqx_modules,
        emqx_bridge
    ];
test_case_specific_apps_spec(TestCase) when
    TestCase =:= t_export_cloud;
    TestCase =:= t_export_cloud_ctl
->
    [
        emqx_auth,
        emqx_auth_mnesia,
        emqx_schema_registry
    ];
test_case_specific_apps_spec(TestCase) when
    TestCase =:= t_schema_registry_import_order
->
    [
        emqx_schema_registry,
        emqx_schema_validation,
        emqx_message_transformation
    ];
test_case_specific_apps_spec(TestCase) when
    TestCase =:= t_exhook_backup
->
    [
        emqx_exhook
    ];
test_case_specific_apps_spec(_TC) ->
    [].
