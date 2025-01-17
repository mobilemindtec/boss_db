-module(boss_db_test_app).

-behaviour(application).

-export([start/2, stop/1, run_init/0, run_setup/0, run_tests/0]).

-spec(start(_,_) -> no_return()).
start(_Type, _StartArgs) ->
    application:load(boss_db),
    run_init(),
    run_setup(),
    run_tests(),
    erlang:halt().

stop(_State) ->
    ok.

get_env(Key, Default) ->
    V = case application:get_env(boss_db, Key) of
        {ok, Val} -> Val;
        _ -> Default
    end,
    V.

run_init() ->
    DBOptions = lists:foldl(fun(OptName, Acc) ->
                case application:get_env(OptName) of
                    {ok, Val} -> [{OptName, Val}|Acc];
                    _ -> Acc
                end
        end, [], [db_port, db_host, db_username, db_password, db_database]),
    DBAdapter = get_env(db_adapter, mock),
    DBShards = get_env(db_shards, []),
    CacheEnable = get_env(cache_enable, false),
    DBOptions1 = [{adapter, list_to_atom(lists:concat([DBAdapter, ""]))},
        {cache_enable, CacheEnable}, {shards, DBShards}|DBOptions],

    boss_db:start(DBOptions1),
    boss_news:start().


run_setup() ->
  {ok, boss_db_test_model} = boss_record_compiler:compile(filename:join(["priv", "test_models", "boss_db_test_model.erl"])),
  {ok, boss_db_test_parent_model} = boss_record_compiler:compile(filename:join(["priv", "test_models", "boss_db_test_parent_model.erl"])),
  DBAdapter = get_env(db_adapter, mock),
  case file:read_file(filename:join(["priv", "test_sql", lists:concat([DBAdapter, ".sql"])])) of
    {ok, FileContents} ->
      lists:map(fun("") -> ok;
                   (Cmd) ->
                        RetVal = boss_db:execute(Cmd),
                        logger:info("Returned: ~p~n", [RetVal])
      end, re:split(FileContents, ";"));
    {error, _Reason} ->
      ok
  end.

run_tests() ->
    %% Mock transaction ensures requests come from the same worker
    boss_db:mock_transaction(fun run_tests_inner/0).

run_tests_inner() ->
  logger:info("~-60s", ["Root test"]),
  ModelText = <<"Economists do it with models">>,
  do(
    fun() ->
        ParentModel = boss_db_test_parent_model:new(id, <<"foo">>),
        {ok, SavedParentModel} = ParentModel:save(),
        Model = boss_db_test_model:new(id, ModelText,
          {{1776, 7, 4}, {0, 0, 0}}, true, 42, 3.14159, SavedParentModel:id()),
        {ok, SavedModel} = Model:save(),
        {SavedModel, SavedParentModel}
    end,
    [
      fun({SavedModel, _}) ->
          {SavedModel:id() =/= id,
            "ID field not generated"}
      end,
      fun({SavedModel, _}) ->
          {SavedModel:some_text() =:= ModelText,
            "Text field not saved correctly"}
      end,
      fun({SavedModel, _}) ->
          {SavedModel:some_integer() =:= 42,
            "Integer field not saved correctly"}
      end,
      fun({SavedModel, _}) ->
          {SavedModel:some_float() =:= 3.14159,
            "Float field not saved correctly"}
      end,
      fun({SavedModel, SavedParentModel}) ->
          {(SavedModel:boss_db_test_parent_model()):id() =:= SavedParentModel:id(),
            "Association doesn't have expected ID"}
      end,
      fun({SavedModel, SavedParentModel}) ->
          {(SavedModel:boss_db_test_parent_model()):some_text() =:= SavedParentModel:some_text(),
              "Association doesn't have expected Text"}
      end
    ],
    [ "Check for record in the database",
      fun({SavedModel, _}) ->
          do(
            fun() ->
                boss_db:find(SavedModel:id())
            end,
            [
              fun(Result) ->
                  {Result:id() =:= SavedModel:id(),
                    "Returned record ID not the same as saved record ID"}
              end,
              fun(Result) ->
                  {Result:some_text() =:= SavedModel:some_text(),
                    "Returned record Text not the same as saved record Text"}
              end,
              fun(Result) ->
                  {Result:some_boolean() =:= SavedModel:some_boolean(),
                    "Returned record Boolean not the same as saved record Boolean"}
              end,
              fun(Result) ->
                  {Result:some_time() =:= SavedModel:some_time(),
                    "Returned record Time not the same as saved record Time"}
              end,
              fun(Result) ->
                  {Result:some_integer() =:= SavedModel:some_integer(),
                    "Returned record Integer not the same as saved record Integer"}
              end,
              fun(Result) ->
                  {Result:some_float() =:= SavedModel:some_float(),
                    "Returned record Float not the same as saved record Float"}
              end
            ], [])
      end,

      "Create more records",
      fun({Model1, _}) ->
          do(
            fun() ->
                % boss_db_test_model:new(id, <<"Economists do it with models">>,
                % {{1776, 7, 4}, {0, 0, 0}}, true, 42, 3.14159),
                {ok, Model2} = (boss_db_test_model:new(id, "Bold coffee",
                    {{1969, 7, 20}, {0, 0, 0}}, false, 100, 5.5, undefined)):save(),
                {ok, Model3} = (boss_db_test_model:new(id, "A Bold Society",
                    {{1984, 1, 1}, {0, 0, 0}}, true, 200, 28.8, undefined)):save(),
                [Model1:id(), Model2:id(), Model3:id()]
            end,
            [
              fun([Id, _, _]) ->
                  Model = boss_db:find(Id),
                  {Model=/=undefined, Id ++ " lost"}
              end,
              fun([_, Id, _]) ->
                  Model = boss_db:find(Id),
                  {Model=/=undefined, Id ++ " lost"}
              end,
              fun([_, _, Id]) ->
                  Model = boss_db:find(Id),
                  {Model=/=undefined, Id ++ " lost"}
              end,
              fun(_) ->
                  Res = boss_db:find(boss_db_test_model, [], [{limit, 1}]),
                  {length(Res) =:= 1, "Max not obeyed"}
              end,
              fun(_) ->
                  Res = boss_db:find(boss_db_test_model, [], [{offset, 1}]),
                  {length(Res) =:= 2, "Skip not obeyed"}
              end,
              fun([_Id1, _Id2, Id3]) ->
                  Res = boss_db:find(boss_db_test_model, [], [{limit, 1}, {order_by, some_text}, {descending, false}]),
                  {(hd(Res)):id() =:= Id3, "Sort ascending failed"}
              end,
              fun([Id1, _Id2, _Id3]) ->
                  Res = boss_db:find(boss_db_test_model, [], [{limit, 1}, {order_by, some_text}, descending]),
                  {(hd(Res)):id() =:= Id1, "Sort descending failed"}
              end,

              fun(_) ->
                  {boss_db:count(boss_db_test_model) =:= 3, "Count failed"}
              end,
              fun(_) ->
                  {boss_db:count(boss_db_test_model, []) =:= 3, "Count with empty conditions failed"}
              end,
              fun(_) ->
                  {boss_db:count(boss_db_test_model, [{some_integer, 'gt', 50}]) =:= 2,
                    "Count with non-trivial conditions failed"}
              end
            ],
            [
              "Run query tests",
              fun(Ids) ->
                  do(fun() -> ok end, [], generate_query_tests(Ids))
              end,

              "Update records",
              fun([Id1|_]) ->
                  do(fun() ->
                        Record = boss_db:find(Id1),
                        UpdatedRecord = Record:set([{some_integer, 43}]),
                        {ok, SavedRecord} = UpdatedRecord:save(),
                        SavedRecord
                    end,
                    [
                      fun(SavedRecord) ->
                          {SavedRecord:some_integer() =:= 43,
                            "Record did not update"}
                      end,
                      fun(_) ->
                          Count = boss_db:count(boss_db_test_model, [{some_integer, 'equals', 43}]),
                          {Count =:= 1, "Updated record not found"}
                      end
                    ], [])
              end,

              "Delete records",
              fun([Id1|_]) ->
                  do(fun() ->
                        boss_db:delete(Id1)
                    end,
                    [
                      fun(RetVal) ->
                          {RetVal =:= ok, "Return value not OK"}
                      end,
                      fun(_RetVal) ->
                          {boss_db:count(boss_db_test_model) =:= 2,
                            "Incorrect # of records in the DB"}
                      end
                    ], [])
              end
            ]
          )
      end
    ]).

do(Fun, Assertions, Continuations) ->
  boss_test:process_assertions_and_continuations(Assertions, Continuations, Fun(),
      fun boss_db:push/0, fun boss_db:pop/0, fun boss_db:dump/0).

query_tests([Id1, Id2, Id3]) ->
  [
    {[],                                                [Id1, Id2, Id3]},

    {[{some_integer, 'equals', 100}],                   [     Id2     ]},
    {[{some_integer, 'not_equals', 100}],               [Id1,      Id3]},
    {[{some_integer, 'gt', 100}],                       [          Id3]},
    {[{some_integer, 'ge', 100}],                       [     Id2, Id3]},
    {[{some_integer, 'lt', 100}],                       [Id1          ]},
    {[{some_integer, 'le', 100}],                       [Id1, Id2     ]},
    {[{some_integer, 'in', {99, 101}}],                 [     Id2     ]},
    {[{some_integer, 'not_in', {99, 101}}],             [Id1,      Id3]},
    {[{some_integer, 'in', [42, 200]}],                 [Id1,      Id3]},
    {[{some_integer, 'not_in', [42, 200]}],             [     Id2     ]},

    {[{some_float, 'equals', 5.5}],                     [     Id2     ]},
    {[{some_float, 'not_equals', 5.5}],                 [Id1,      Id3]},
    {[{some_float, 'gt', 5.5}],                         [          Id3]},
    {[{some_float, 'ge', 5.5}],                         [     Id2, Id3]},
    {[{some_float, 'lt', 5.5}],                         [Id1          ]},
    {[{some_float, 'le', 5.5}],                         [Id1, Id2     ]},
    {[{some_float, 'in', {20, 30}}],                    [          Id3]},
    {[{some_float, 'not_in', {20, 30}}],                [Id1, Id2     ]},
    {[{some_float, 'in', [5.5, 28.8]}],                 [     Id2, Id3]},
    {[{some_float, 'not_in', [5.5, 28.8]}],             [Id1          ]},

    {[{some_boolean, 'equals', true}],                  [Id1,      Id3]},
    {[{some_boolean, 'not_equals', true}],              [     Id2     ]},

    {[{some_time, 'equals', {{1969, 7, 20}, {0,0,0}}}], [     Id2     ]},
    {[{some_time, 'not_equals',{{1969,7,20},{0,0,0}}}], [Id1,      Id3]},
    {[{some_time, 'gt', {{1969, 7, 20}, {0, 0, 0}}}],   [          Id3]},
    {[{some_time, 'ge', {{1969, 7, 20}, {0, 0, 0}}}],   [     Id2, Id3]},
    {[{some_time, 'lt', {{1969, 7, 20}, {0, 0, 0}}}],   [Id1          ]},
    {[{some_time, 'le', {{1969, 7, 20}, {0, 0, 0}}}],   [Id1, Id2     ]},

    {[{some_text, 'equals', "Bold coffee"}],            [     Id2     ]},
    {[{some_text, 'not_equals', "Bold coffee"}],        [Id1,      Id3]},
    {[{some_text, 'matches', "Bold [cS]"}],             [     Id2, Id3]},
    {[{some_text, 'not_matches', "Bold [cS]"}],         [Id1          ]},
    {[{some_text, 'contains', "Bold"}],                 [     Id2, Id3]},
    {[{some_text, 'not_contains', "Bold"}],             [Id1          ]},
    {[{some_text, 'contains_all', ["Bold", "Society"]}],
        [          Id3]},
    {[{some_text, 'not_contains_all', ["Bold", "Society"]}],
        [Id1, Id2     ]},
    {[{some_text, 'contains_any', ["models", "Society"]}],
        [Id1,      Id3]},
    {[{some_text, 'contains_none', ["models", "Society"]}],
        [     Id2     ]}

  ].

generate_query_tests(Ids) ->
  lists:foldr(fun({Conditions, ModelIds}, Acc) ->
        [io_lib:format("Find: ~p", [Conditions]),
          fun(_) ->
              do(
                fun() ->
                    Results = boss_db:find(boss_db_test_model, Conditions),
                    lists:map(fun(Res) -> Res:id() end, Results)
                end,
                [
                  fun(ResultIds) ->
                      {length(ResultIds) =:= length(ModelIds), "Query returned incorrect number of records"}
                  end,
                  fun(ResultIds) ->
                      {lists:sort(ResultIds) =:= lists:sort(ModelIds), "Query returned an incorrect set"}
                  end
                ], [])
          end | Acc]
    end, [], query_tests(Ids)).
