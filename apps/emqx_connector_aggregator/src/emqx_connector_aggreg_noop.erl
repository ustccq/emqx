%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_connector_aggreg_noop).

-moduledoc """
No-op implementation for `emqx_connector_aggregator` which returns input records without
any change.  Main purpose is to delegate handling the raw records to a transfer module
that requires more intimate handling of the record and keeping of extra metadata.
""".

-behaviour(emqx_connector_aggreg_container).

%% `emqx_connector_aggreg_container' API
-export([
    new/1,
    fill/2,
    close/1
]).

-export_type([container/0, options/0]).

%%------------------------------------------------------------------------------
%% Type declarations
%%------------------------------------------------------------------------------

-record(noop, {}).

-opaque container() :: #noop{}.

-type options() :: #{}.

%%------------------------------------------------------------------------------
%% `emqx_connector_aggreg_container' API
%%------------------------------------------------------------------------------

-spec new(options()) -> container().
new(_) ->
    #noop{}.

-spec fill([emqx_connector_aggregator:record()], container()) ->
    {[emqx_connector_aggregator:record()], container()}.
fill(Records, #noop{} = Container) ->
    {Records, Container}.

-spec close(container()) -> nil().
close(#noop{}) ->
    [].
