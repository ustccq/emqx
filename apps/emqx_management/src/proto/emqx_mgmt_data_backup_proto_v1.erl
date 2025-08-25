%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_mgmt_data_backup_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,
    import_file/4,
    list_files/2,
    read_file/3,
    delete_file/3
]).

-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.4.0".

-spec list_files([node()], timeout()) ->
    emqx_rpc:erpc_multicall({non_neg_integer(), map()}).
list_files(Nodes, Timeout) ->
    erpc:multicall(Nodes, emqx_mgmt_data_backup, list_files, [], Timeout).

-spec import_file(node(), node(), binary(), timeout()) ->
    emqx_mgmt_data_backup:import_res() | {badrpc, _}.
import_file(Node, FileNode, FileName, Timeout) ->
    rpc:call(Node, emqx_mgmt_data_backup, maybe_copy_and_import, [FileNode, FileName], Timeout).

-spec read_file(node(), binary(), timeout()) ->
    {ok, binary()} | {error, _} | {badrpc, _}.
read_file(Node, FileName, Timeout) ->
    rpc:call(Node, emqx_mgmt_data_backup, read_file, [FileName], Timeout).

-spec delete_file(node(), binary(), timeout()) -> ok | {error, _} | {badrpc, _}.
delete_file(Node, FileName, Timeout) ->
    rpc:call(Node, emqx_mgmt_data_backup, delete_file, [FileName], Timeout).
