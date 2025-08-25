%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_s3tables_aggreg_partitioned_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/emqx_bridge_s3tables.hrl").

%%------------------------------------------------------------------------------
%% Type declarations
%%------------------------------------------------------------------------------

-define(QUERY_ENDPOINT, <<"http://query:8090">>).

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

new_opts(Opts) ->
    Schema = #{
        <<"type">> => <<"struct">>,
        <<"schema-id">> => 0,
        <<"fields">> => [
            #{
                <<"id">> => 1,
                <<"name">> => <<"bar">>,
                <<"required">> => false,
                <<"type">> => <<"string">>
            },
            #{
                <<"id">> => 2,
                <<"name">> => <<"baz">>,
                <<"required">> => false,
                <<"type">> => <<"int">>
            }
        ]
    },
    PartitionSpec = #{
        <<"spec-id">> => 0,
        <<"fields">> => [
            #{
                <<"field-id">> => 1001,
                <<"source-id">> => 1,
                <<"name">> => <<"bar-ps">>,
                <<"transform">> => <<"bucket[3]">>
            }
        ]
    },
    LoadedTable = emqx_bridge_s3tables_logic_tests:mk_loaded_table(#{
        schema => Schema,
        partition_spec => PartitionSpec
    }),
    {ok, #{
        ?partition_spec := #partitioned{fields = PartitionFields},
        ?avro_schema := AvroSc,
        ?avro_schema_json := AvroScJSON
    }} =
        emqx_bridge_s3tables_logic:parse_loaded_table(LoadedTable),
    ContainerType = maps:get(type, Opts),
    InnerContainerOpts = innert_container_opts(ContainerType, AvroSc, AvroScJSON),
    #{
        inner_container_opts => InnerContainerOpts,
        partition_fields => PartitionFields
    }.

innert_container_opts(avro, AvroSc, _AvroScJSON) ->
    #{
        type => avro,
        writer_opts =>
            #{
                schema => AvroSc,
                root_type => ?ROOT_AVRO_TYPE
            }
    };
innert_container_opts(parquet, _AvroSc, AvroScJSON) ->
    ParquetSchema = parquer_schema_avro:from_avro(AvroScJSON),
    #{
        type => parquet,
        writer_opts => #{
            schema => ParquetSchema,
            writer_opts => #{}
        }
    }.

fill_close(Records, Container) ->
    %% We insert one-by-one to test the case when the partition key is known.
    {Output, Meta, ContainerFinal} =
        lists:foldl(
            fun(Record, {AccOut0, AccMeta0, AccCont}) ->
                {O, M, C} = emqx_bridge_s3tables_aggreg_partitioned:fill([Record], AccCont),
                AccOut = maps:merge_with(fun(_PKs, A, B) -> [A | B] end, AccOut0, O),
                AccMeta = merge_metas(AccMeta0, M),
                {AccOut, AccMeta, C}
            end,
            {#{}, #{}, Container},
            Records
        ),
    Trailer = emqx_bridge_s3tables_aggreg_partitioned:close(ContainerFinal),
    OutputFinal = maps:merge_with(fun(_PK, A, B) -> [A | B] end, Output, Trailer),
    {OutputFinal, Meta}.

decode(OutputsPerPKs, #{type := avro}) ->
    maps:map(
        fun(_PKs, IOData) ->
            DecodeOpts = avro:make_decoder_options([{map_type, map}, {record_type, map}]),
            {_Header, _Sc, Blocks} = avro_ocf:decode_binary(iolist_to_binary(IOData), DecodeOpts),
            Blocks
        end,
        OutputsPerPKs
    );
decode(OutputsPerPKs, #{type := parquet}) ->
    maps:map(
        fun(_PKs, IOData) ->
            read_parquet(IOData)
        end,
        OutputsPerPKs
    ).

roundtrip(Records, Container, Opts) ->
    {OutputsPerPKS, Meta} = fill_close(Records, Container),
    {decode(OutputsPerPKS, Opts), Meta}.

merge_metas(A, B) ->
    maps:merge_with(
        fun(_PKs, C, D) ->
            maps:merge_with(fun(_K, E, F) -> E + F end, C, D)
        end,
        A,
        B
    ).

read_parquet(Raw) ->
    Method = post,
    URI = iolist_to_binary(lists:join("/", [?QUERY_ENDPOINT, "read-parquet"])),
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(Method, {URI, [], "application/octet-stream", Raw}, [], [
            {body_format, binary}
        ]),
    emqx_utils_json:decode(Body).

%%------------------------------------------------------------------------------
%% Test cases
%%------------------------------------------------------------------------------

roundtrip_test_() ->
    [
        %% We can't run this parquet unit test in CI because we need a separate "oracle"
        %% container to read the data back...
        %% {"parquet", ?_test(test_roundtrip(#{type => parquet}))},
        {"avro", ?_test(test_roundtrip(#{type => avro}))}
    ].

test_roundtrip(Opts) ->
    Records = lists:map(
        fun(N) ->
            #{
                <<"bar">> => integer_to_binary(N),
                <<"baz">> => N
            }
        end,
        lists:seq(1, 10)
    ),
    Container = emqx_bridge_s3tables_aggreg_partitioned:new(new_opts(Opts)),
    ?assertMatch(
        {
            #{
                [0] :=
                    [
                        #{<<"bar">> := <<"2">>, <<"baz">> := 2},
                        #{<<"bar">> := <<"3">>, <<"baz">> := 3},
                        #{<<"bar">> := <<"4">>, <<"baz">> := 4},
                        #{<<"bar">> := <<"5">>, <<"baz">> := 5},
                        #{<<"bar">> := <<"10">>, <<"baz">> := 10}
                    ],
                [1] := [#{<<"bar">> := <<"1">>, <<"baz">> := 1}],
                [2] :=
                    [
                        #{<<"bar">> := <<"6">>, <<"baz">> := 6},
                        #{<<"bar">> := <<"7">>, <<"baz">> := 7},
                        #{<<"bar">> := <<"8">>, <<"baz">> := 8},
                        #{<<"bar">> := <<"9">>, <<"baz">> := 9}
                    ]
            },
            #{
                [0] := #{?num_records := 5},
                [1] := #{?num_records := 1},
                [2] := #{?num_records := 4}
            }
        },
        roundtrip(Records, Container, Opts)
    ),
    ok.

incompatible_partitioned_data_test() ->
    Container = emqx_bridge_s3tables_aggreg_partitioned:new(new_opts(#{type => avro})),
    %% `bar` should be a string
    BadRecord = #{
        <<"bar">> => true,
        <<"baz">> => 999
    },
    ?assertExit(
        {upload_failed, {data, {incompatible_value, <<"bar-ps">>, true}}},
        fill_close([BadRecord], Container)
    ),
    ok.
