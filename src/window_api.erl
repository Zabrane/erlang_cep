%% Author: dan
%% Created: 5 Nov 2012
%% Description: TODO: Add description to sized_window_api
-module(window_api).

%%
%% Include files
%%

-include("window.hrl").
-include_lib("eunit/include/eunit.hrl").

%%
%% Exported Functions
%%
-export([add_data/2, do_add_data/2, run_row_query/3, run_reduce_query/2, next_position/3,
		 subscribe/2, unSubscribe/2, do_subscribe/2, do_unSubscribe/2, is_subscribed/2,
		 create_json/1, create_standard_row_function/0, create_reduce_function/0, create_single_json/2,
		 create_match_recognise_row_function/0, remove_match/2, clock_tick/1, generate_tick/2,
		 add_json_parse_function/2, create_json_parse_function/0, view_json_parse_function/1, search/2, 
		 do_search/2]).
%%
%% API Functions
%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A json parse function is used to extract
%%      pararameters from a json row.
%%		For example lets say that this json is added 
%% 		to the system {"glossary": {"title": "example glossary"}}
%%		and we want to extract the title of the book, then
%%		we would use the parse function to pull this out.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
add_json_parse_function(WindowName, JSONParseFunction) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	ok = gen_server:cast(WindowPid, {jsonParseFunction, JSONParseFunction}).

view_json_parse_function(WindowName) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	{ok, ParseFunction} = gen_server:call(WindowPid, {checkJsonParseFunction}),
	ParseFunction.	

generate_tick(Delay, Process) ->
	receive
		tick ->
			Process ! tick,
			erlang:send_after(Delay, self(), tick);
		Error ->
			io:format("Got error ~p ~n", [Error])
	after 2000 ->
			io:format("after 2000 ~n")
	end,
	generate_tick(Delay, Process).

do_search(WindowName, SearchParameter) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	gen_server:call(WindowPid, {search, SearchParameter}).
			
subscribe(WindowName, Pid) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	ok = gen_server:cast(WindowPid, {subscribe, Pid}).

unSubscribe(WindowName, Pid) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	ok = gen_server:cast(WindowPid, {unSubscribe, Pid}).

is_subscribed(WindowName, Pid) ->
	[{_WindowName,WindowPid}] = ets:lookup(window_ets, WindowName),
	{ok, Ans} = gen_server:call(WindowPid, {isSubscribed, Pid}),
	Ans.

do_subscribe(Pid, State=#state{pidList=PidList}) ->
	State#state{pidList = [Pid | PidList]}.

do_unSubscribe(Pid, State=#state{pidList=PidList}) ->
	State#state{pidList = lists:delete(Pid, PidList)}.

%% @doc Add data to a timed window
add_data(Data, Pid) ->
	ok = gen_server:cast(Pid, {add_data, Data}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Every second we generate a tick which is used to :-
%% 
%%  	Increment the position counter by 1 and wrap around the window if necessary
%%  	For the new second mutate the timingsDictionary by removing the elements from the new 
%%		list and putting them in the old list.
%%
%%  	Expire the entirity of the oldList in the last second as all elements should now be expired.
%%	@end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
clock_tick(State=#state{results=ResultsDict,
						matches=MatchList,
						position=Position,
						queryParameters={NumberOfMatches, WindowSize, time, _Consecutive, MatchType, ResetStrategy},
						jsPort=JSPort,
						pidList = PidList,
						timingsDict = TimingsDict}) ->
	
	%% Not the cleanest code in the world.  New Position stores the second within the window.
    %% This needs to roll around hence passing in the size parameter.
	NewPosition = next_position(Position, WindowSize, size),
	
	MutatedMatchList = case NewPosition of
							0 when MatchType == every ->
								match_engine:run_reduce_function(PidList, MatchList, NumberOfMatches, ResultsDict, JSPort, ResetStrategy);
							_ ->
								MatchList
						end,
		
	{ResetTimingsDict, ResetMatchList, ResetResultsDict} = 
			expiry_api:expiry_list_reset_old(expiry_api:expiry_list_swap(TimingsDict, NewPosition), Position, MutatedMatchList, ResultsDict),
	
	State#state{position = NewPosition, timingsDict = ResetTimingsDict, matches = ResetMatchList, results = ResetResultsDict}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc	Called from the Genserver to add data to a sized window
%% 		Runs the row function
%% 		Mutates the match dictionary
%% 		Moves to the next position within the sized window
%% 		Mutates the results dictionary.  The results dictionary is created to be the size 
%% 		of the window.  Every time a new row is added the position is incremented
%% 		until it equals the size of the window, where it resets to zero, and new rows
%% 		overwrite the old ones.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data(Row, State=#state{results=Results, 
							  matches=Matches, 
							  position=Position, 
							  queryParameters={_NumberOfMatches, WindowSize, size, Consecutive, MatchType, _ResetStrategy} = QueryParameters,
							  jsPort=JSPort,
							  pidList=PidList}) ->
	
	{ok, RowResult} = run_row_query(JSPort, Row, []),
		
	{NewMatches, FirstPassed} = case RowResult of 
					[] ->
						%% If consecutive then a fail will clear all state otherwise take the old position out of all of the match lists
						case Consecutive of
							consecutive ->
								{[[]], false};
							nonConsecutive ->
								{remove_match(Matches, Position), false}
						end;
					_ ->
						{add_match(remove_match(Matches, Position), Position, MatchType), true}
				end,
	
	ResultsDict = add_to_results_dictionary(Results, Row, RowResult, Position),
	
	%% Move to next position
	NewPosition = next_position(Position, WindowSize, size),
	
	MutatedMatches = match_engine:do_match(QueryParameters, ResultsDict, NewMatches, JSPort, Position, PidList, FirstPassed),

	%% Return the state
  	State#state{position = NewPosition, results = ResultsDict, matches = MutatedMatches};

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Called by a feed_genserver to add data to a timed window %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data(Row, State=#state{results=Results, 
							  matches=Matches, 
							  position=Position, 
							  queryParameters={_NumberOfMatches, WindowSize, time, Consecutive, MatchType, _ResetStrategy} = QueryParameters,
							  jsPort=JSPort,
							  pidList=PidList,
							  sequenceNumber=SequenceNumber,
							  timingsDict=TimingsDict}) ->
		
	Now = os:timestamp(),
	NewSequenceNumber = SequenceNumber + 1,
	
	{ok, RowResult} = run_row_query(JSPort, Row, []),
			
	{NewMatches, FirstPassed, NewTimingsDict} = case RowResult of 
					[] ->
						%% If consecutive then a fail will clear all state otherwise take the old position out of all of the match lists
						case Consecutive of
							consecutive ->
								{[[]], false, TimingsDict};
							nonConsecutive ->
								{Matches, false, TimingsDict}
						end;
					_ ->
						{add_match(Matches, SequenceNumber, MatchType), true, expiry_api:add_to_expiry_dict(TimingsDict, {SequenceNumber, Now}, Position)}
				end,

	ResultsDict = add_to_results_dictionary(Results, Row, RowResult, SequenceNumber),
	
	{FilteredTimingsDict, FilteredMatchList, FilteredResultsDict} = 
			expiry_api:expire_from_expiry_dict(NewTimingsDict, SequenceNumber, NewMatches, ResultsDict, Now, WindowSize),
		
	MatchedMatches = match_engine:do_match(QueryParameters, FilteredResultsDict, FilteredMatchList, JSPort, SequenceNumber, PidList, FirstPassed),
	
	%% Return the state
  	State#state{results = FilteredResultsDict, matches = MatchedMatches, timingsDict=FilteredTimingsDict, sequenceNumber = NewSequenceNumber}.

%% @doc Move to the next window position. A window has a fixed size, when we overflow move back to 0.
next_position(OldPosition, WindowSize, size) when ((WindowSize-1) == OldPosition) ->
	0;

next_position(OldPosition, _WindowSize, _) ->
	OldPosition + 1.

%% @doc Search the results dictionary within a window for a range of values [val1, '_' , val2]
%%      where _ = don't care and the list has to be the size of the result list.
search(SearchParameters, _State=#state{results=Results}) ->
	runSearch(SearchParameters, Results).

runSearch(SearchParameters, Results) ->
	dict:fold(fun (_Key, {_Row,Value}, Acc) ->
				case searchValue(SearchParameters, Value) of
					true ->
						[Value] ++ Acc;
					false ->
						Acc
				end
 			end, [], Results).
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%Internal Stuff
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Take a list of search parameters [val1, '_', val2] and check against a list of results to
%%      return true if the search parameters match and false otherwise.
searchValue(SearchParameters, Values) ->
	
	SearchList = lists:zipwith(fun(SP,Val) -> match(SP, Val) end, SearchParameters, Values),
	
	lists:foldl(fun(Value, Acc) ->
						case Acc of
								false ->
									Acc;
								true ->
									Value
						end
				end, true, SearchList).

match('_', _Value) ->
	true;

match(Parameter, Value) when Parameter == Value ->
	true;

match(_Parameter, _Value) ->
	false.

%% @doc Run the row query passing in an empty second parameter meaning that we are not matching
%% 		against any other data in the window
%% @end
run_row_query(JSPort, Data, []) ->
	js:call(JSPort, <<"rowFunction">>, [Data, [], true]);

%% @doc Run the row query in match select mode (looking against old data)
run_row_query(JSPort, Data, PrevData) ->
	js:call(JSPort, <<"rowFunction">>, [Data, PrevData, false]).

%% @doc Run the reduce function
run_reduce_query(JSPort, Results) ->	
	js:call(JSPort, <<"reduceFunction">>, Results).

%% @doc Add to results dictionary
add_to_results_dictionary(ResultsDict, Row, Result, Position) ->
	dict:store(Position, {Row, Result}, ResultsDict).

add_match([[]], Position, matchRecognise) ->
	[[Position]];

%% @doc If we don't have an empty list then do nothing as the recognise happens within the match_engine is_match_recognise function
add_match(Matches, _Position, matchRecognise) ->
	Matches;

add_match(Matches, Position, _MatchType) ->
	[X ++ [Position] || X <- Matches].

remove_match(Matches, Position) ->
	[lists:delete(Position, X) || X <- Matches].

%% @doc Parse a parameter from an input document.
parse_parameter(json, Row, Parameter, JSPort) ->
	%% I hate parsing json in erlang!
	js:call(JSPort, <<"parseJSON">>, Parameter, Row);

parse_parameter(array, Row, Position, JSPort) ->
	lists:nth(Position, Row).

create_json_parse_function() ->
	<<"var parseJSON = function(parameter, row){
							var myObject = JSON.parse(row);

							for (var key in myObject) {
  								if(key == parameter){
    								return(myObject[key]);
    								break;
  								}
							} 
		">>.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Test Search function
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

create_results_dict() ->
	dict:store(2, {"", ["Goog", 1.01, 13]}, dict:store(1, {"", ["Goog", 1.00, 12]}, dict:new())).

do_pass_search_test() ->	
	?assertEqual([["Goog", 1.01, 13], ["Goog", 1.00, 12]], 
				 	runSearch(["Goog", '_', '_'], create_results_dict())). 

do_pass_search_13_test() ->
	?assertEqual([["Goog", 1.01, 13]], runSearch(["Goog", '_', 13], create_results_dict())). 

do_pass_search_fail_test() ->
	?assertEqual([], runSearch(["Goog1", '_', 13], create_results_dict())). 
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
%% Size based window Tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A Test that starts a consecutive match recognise window which does not
%% 		restart after the reduce function runs.
%%
%% 		The match recognise should fire for each row as the price and volume keep increasing
%%
%% 		Therefore every match should go into the match list, and the list should roll around as the 
%% 		window rolls around until we reach json 6 which does not match so as this is a consecutive 
%% 		window and this element does not pass the basic match we should end up with an empty
%% 		match list.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_matchRecognise_consecutive_noRestart_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}, {resetStrategy, noRestart}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[0,1,2]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
	
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[0,1,2,3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.05", "14"),
	
	NewState5 = do_add_data(Json5, NewState4),
	?assertEqual([[1,2,3,0]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.05,14]}, dict:fetch(0, NewState5#state.results)),
	
	%% Not matched so match list should hold last element
	Json6 = create_single_json("0.05", "1"),
	
	NewState6 = do_add_data(Json6, NewState5),
	?assertEqual([[]], NewState6#state.matches),
	?assertEqual(2, NewState6#state.position),
	%% should be empty as initial match failed.
	?assertEqual({Json6, []}, dict:fetch(1, NewState6#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc	A test that creates a match recognise window that looks for consecutive matches and restarts
%% 		once the query fires.
%%
%% 		Each row should match, then the match list should reset once 3 matches are made.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_matchRecognise_consecutive_restart_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a consecutive match recognise window that initially passes, then fails.
%% 		The net result should be that the match window grows, and then reverts back to the lat match
%% 		but wait you scream why is the last failed match in the window there.  Well remember that
%% 		there are two parts to a match recognise query.  The initial test makes sure that the match
%% 		passes a test.  The second part then compares the next and previous values.  The last match
%% 		passes the initial test, but fails the second.  It therefore deserves to be in the match list
%% 		so it can be matched against the next row.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_matchRecognise_consecutive_fail_restart_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("0.99", "9"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[2]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,0.99,9]}, dict:fetch(2, NewState3#state.results)),

	Json4 = create_single_json("0.98", "8"),
	
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,0.98,8]}, dict:fetch(3, NewState4#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a consecutive match recognise window where initially two rows
%% 		match.  The third row passes the initial part of the match recognise, but fails the
%% 		previous value check.  As the failed row passes the initial check it should
%% 		be put into the match list so that the next row is matched against it.
%%
%% 		The test then goes on to add another two rows which match, so that
%% 		the number of consecutive matches = 3 and the reduce function runs
%% 		resetting the match list.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%  
do_add_data_matchRecognise_consecutive_fail_restart_then_ok_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("0.99", "9"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[2]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,0.99,9]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.07", "19"),
	
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[2,3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.07,19]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.08", "20"),
	
	%% Query fired and reset so should return empty
	NewState5 = do_add_data(Json5, NewState4),
	?assertEqual([[]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.08,20]}, dict:fetch(0, NewState5#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a window that runs a nonConsecutive match recognise query.  NonConsecutive
%% 		match recognise windows are a little strange in that the match list can become a list of lists if 
%% 		a match query passes the inital match, but fails the previous match check.
%%
%% 		After the match fails more rows that pass are added until a reduce function fires.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
do_add_data_matchRecognise_non_consecutive_fail_restart_then_ok_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}, {consecutive, nonConsecutive}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	
	Json3 = create_single_json("0.99", "9"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[2],[0,1]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	
	Json4 = create_single_json("1.07", "19"),
	
	%% [0,1,3] should fire
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[2,3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	
	Json5 = create_single_json("1.08", "20"),
	
	%% Query fired and reset so should return empty
	NewState5 = do_add_data(Json5, NewState4),
	?assertEqual([[]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc This test is similar to the test above, but the row that
%% 		fails the match recognise is a total fail.  Therefore we do 
%% 		not create a list of lists, but leave the match list as it was before.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_matchRecognise_non_consecutive_total_fail_restart_then_ok_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {matchType, matchRecognise}, {consecutive, nonConsecutive}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	
	Json3 = create_single_json("0.01", "1"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[0,1]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	
	Json4 = create_single_json("1.07", "19"),
	
	%% [0,1,3] should fire
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a window that runs a standard consecutive query.
%% 		Rows which match are applied until we have the required three matches, when the
%% 		reduce function runs and clears down the match list.  
%%
%% 		More rows are applied so that the query fires again and resets.
%%
%% 		Finally two more rows are added.  One that passes, and one that fails.
%% 		As this is a consecutive window the failure forces the MatchList to reset.
%% 		N.B. by default queries have the restart flag set.  Which means that the matchList is 
%% 		cleared after the reduce function runs.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_standard_consecutive_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
    NewState3 = do_add_data(Json3, NewState2),
	
	%% Should have fired so now empty
	?assertEqual([[]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
    NewState4 = do_add_data(Json4, NewState3),
	
	?assertEqual([[3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.05", "14"),
    NewState5 = do_add_data(Json5, NewState4),
	
	?assertEqual([[3,0]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.05,14]}, dict:fetch(0, NewState5#state.results)),
	
	Json6 = create_single_json("1.06", "15"),
    NewState6 = do_add_data(Json6, NewState5),
	
	%% Should fire again
	?assertEqual([[]], NewState6#state.matches),
	?assertEqual(2, NewState6#state.position),
	?assertEqual({Json6, [<<"GOOG">>,1.06,15]}, dict:fetch(1, NewState6#state.results)),
	
	Json7 = create_single_json("1.07", "16"),
    NewState7 = do_add_data(Json7, NewState6),
	
	?assertEqual([[2]], NewState7#state.matches),
	?assertEqual(3, NewState7#state.position),
	?assertEqual({Json7, [<<"GOOG">>,1.07,16]}, dict:fetch(2, NewState7#state.results)),
	
	%% Should reset as this should not fire
	Json8 = create_single_json("0.97", "16"),
    NewState8 = do_add_data(Json8, NewState7),
	
	?assertEqual([[]], NewState8#state.matches),
	?assertEqual(0, NewState8#state.position),
	?assertEqual({Json8, []}, dict:fetch(3, NewState8#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a window that runs a nonConsecutive standard match query.
%%
%% 		Initially the first three rows match, so the query fires,  then another three rows 
%% 		are added that fire again.  (This is testing what happens when a window rolls around)
%%
%% 		Finally a row is added that passes, followed by one that fails.  The result should be
%% 		a match list that contains the last match.
%%
%% 		If this were a consecutive window the match list would empty
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
do_add_data_standard_non_consecutive_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {consecutive, nonConsecutive}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
    NewState3 = do_add_data(Json3, NewState2),
	
	%% Should have fired so now empty
	?assertEqual([[]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
    NewState4 = do_add_data(Json4, NewState3),
	
	?assertEqual([[3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.05", "14"),
    NewState5 = do_add_data(Json5, NewState4),
	
	?assertEqual([[3,0]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.05,14]}, dict:fetch(0, NewState5#state.results)),
	
	Json6 = create_single_json("1.06", "15"),
    NewState6 = do_add_data(Json6, NewState5),
	
	%% Should fire again
	?assertEqual([[]], NewState6#state.matches),
	?assertEqual(2, NewState6#state.position),
	?assertEqual({Json6, [<<"GOOG">>,1.06,15]}, dict:fetch(1, NewState6#state.results)),
	
	Json7 = create_single_json("1.07", "16"),
    NewState7 = do_add_data(Json7, NewState6),
	
	?assertEqual([[2]], NewState7#state.matches),
	?assertEqual(3, NewState7#state.position),
	?assertEqual({Json7, [<<"GOOG">>,1.07,16]}, dict:fetch(2, NewState7#state.results)),
	
	%% Should reset as this should not fire
	Json8 = create_single_json("0.97", "16"),
    NewState8 = do_add_data(Json8, NewState7),
	
	?assertEqual([[2]], NewState8#state.matches),
	?assertEqual(0, NewState8#state.position),
	?assertEqual({Json8, []}, dict:fetch(3, NewState8#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a window that runs a non consecutive query that alternates
%% 		between matching and not matching.
%% 
%% 		The purpose of this test is to see if the match list updates correctly as the
%% 		window rolls around.
%%
%% 		In the end three rows match and the query should fire.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_standard_non_consecutive_with_window_roll_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {consecutive, nonConsecutive}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("0.99", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, []}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
    NewState3 = do_add_data(Json3, NewState2),
	
	?assertEqual([[0,2]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("0.99", "13"),
    NewState4 = do_add_data(Json4, NewState3),
	
	?assertEqual([[0,2]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, []}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("0.99", "14"),
    NewState5 = do_add_data(Json5, NewState4),
	
	?assertEqual([[2]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, []}, dict:fetch(0, NewState5#state.results)),
	
	Json6 = create_single_json("1.06", "15"),
    NewState6 = do_add_data(Json6, NewState5),
	
	%% Should fire again
	?assertEqual([[2,1]], NewState6#state.matches),
	?assertEqual(2, NewState6#state.position),
	?assertEqual({Json6, [<<"GOOG">>,1.06,15]}, dict:fetch(1, NewState6#state.results)),
	
	Json7 = create_single_json("1.07", "16"),
    NewState7 = do_add_data(Json7, NewState6),
	
	%% 1,2 as the query fired on pos2 as it was taken out of the window.  So we removed 2 and added it back again.
	?assertEqual([[1,2]], NewState7#state.matches),
	?assertEqual(3, NewState7#state.position),
	?assertEqual({Json7, [<<"GOOG">>,1.07,16]}, dict:fetch(2, NewState7#state.results)),
	
	Json8 = create_single_json("1.22", "16"),
    NewState8 = do_add_data(Json8, NewState7),
	
	?assertEqual([[]], NewState8#state.matches),
	?assertEqual(0, NewState8#state.position),
	?assertEqual({Json8, [<<"GOOG">>,1.22,16]}, dict:fetch(3, NewState8#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a standard window and runs a consecutive query that does not reset when the reduce function runs
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
do_add_data_standard_consecutive_noRestart_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {resetStrategy, noRestart}],
	InitialState = create_initial_state(QueryParameters, create_match_recognise_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
	NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(2, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
	
	NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[0,1,2]], NewState3#state.matches),
	?assertEqual(3, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
	
	NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[0,1,2,3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.05", "14"),
	
	NewState5 = do_add_data(Json5, NewState4),
	?assertEqual([[1,2,3,0]], NewState5#state.matches),
	?assertEqual(1, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.05,14]}, dict:fetch(0, NewState5#state.results)),
	
	%% Not matched so match list should now be [[]]
	Json6 = create_single_json("0.05", "1"),
	
	NewState6 = do_add_data(Json6, NewState5),
	?assertEqual([[]], NewState6#state.matches),
	?assertEqual(2, NewState6#state.position),
	%% should be empty as initial match failed.
	?assertEqual({Json6, []}, dict:fetch(1, NewState6#state.results)).

create_json(Data) ->
	lists:foldl(fun({Price, Volume}, Acc) -> 
					[create_single_json(Price, Volume) | Acc]
				end, [], lists:reverse(Data)).

create_single_json(Price, Volume) ->
	list_to_binary(["{\"symbol\": \"GOOG\",\"price\": ", Price , ",\"volume\": ",  Volume,"}"]).

create_standard_row_function() ->
	<<"var rowFunction = function(row, otherRow, first){
							
							var myObject = JSON.parse(row);
							symbol = myObject.symbol;
							price = myObject.price;
							volume = myObject.volume;

							if (price > 1.00){
								return [symbol, price, volume];
							}
							
							return []}">>.

create_match_recognise_row_function() ->
	<<"var rowFunction = function(row, otherRow, first){
							
							var myObject = JSON.parse(row);

							symbol = myObject.symbol;
							price = myObject.price;
							volume = myObject.volume;

							if (first == true){

								if (price > 0.50){
									return [symbol, price, volume];
								}

								else{
									return [];
								}
							}

							else{
		
								var prevObject = JSON.parse(otherRow);								

								if (volume > prevObject.volume){
									return true;
								}

								else{
									return false;
								}
							}
							
						}">>.

create_reduce_function() ->
	<<"var reduceFunction = function(matches){
							var sum = 0;

							for(var i=0; i<matches.length; i++) {
								var match = matches[i];
								sum += match[2];
							}

							if (sum > 0){
								return sum / matches.length;
							}

							

							return 0}">>.

create_initial_state(QueryParameterList, RowFunction, ReduceFunction) ->
	erlang_js:start(),

	{ok, JSPort} = js_driver:new(),
	
	js:define(JSPort, RowFunction),
	js:define(JSPort, ReduceFunction),

	#state{name = "test", position = 0, results = dict:new(), matches = [[]], rowQuery = create_standard_row_function(), 
				reduceQuery = create_reduce_function(), queryParameters = query_parameter_api:get_parameters(QueryParameterList), 
				jsPort = JSPort, pidList = [], sequenceNumber = 0, timingsDict=dict:new()}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that starts everything up and then subscribes this process for
%% 		updates, and checks that it is subscribed.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 
%%subscribe_test() ->
%%	erlang_js:start(),
%%	window_sup:start_link(testFeed1),
%%	QueryParameters = {3, 4, size, consecutive, standard, restart},
%%	window_sup:start_child(testFeed1, testWin111, create_standard_row_function(), create_reduce_function(), QueryParameters),
%%	subscribe(testWin111, self()),
%%	?assertEqual(is_subscribed(testWin111, self()), true).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Timed Window Tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a 4 second timed window looking for three consecutive matches that fires twice
%% 		and then fails.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

timed_do_add_data_standard_consecutive_test() ->
	QueryParameters = [{numberOfMatches, 3}, {windowSize, 4}, {windowType, time}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(0, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),
	
	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(0, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
    NewState3 = do_add_data(Json3, NewState2),
	
	%% Should have fired so now empty
	?assertEqual([[]], NewState3#state.matches),
	?assertEqual(0, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
    NewState4 = do_add_data(Json4, NewState3),
	
	?assertEqual([[3]], NewState4#state.matches),
	?assertEqual(0, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	Json5 = create_single_json("1.05", "14"),
    NewState5 = do_add_data(Json5, NewState4),
	
	?assertEqual([[3,4]], NewState5#state.matches),
	?assertEqual(0, NewState5#state.position),
	?assertEqual({Json5, [<<"GOOG">>,1.05,14]}, dict:fetch(4, NewState5#state.results)),
	
	Json6 = create_single_json("1.06", "15"),
    NewState6 = do_add_data(Json6, NewState5),
	
	%% Should fire again
	?assertEqual([[]], NewState6#state.matches),
	?assertEqual(0, NewState6#state.position),
	?assertEqual({Json6, [<<"GOOG">>,1.06,15]}, dict:fetch(5, NewState6#state.results)),
	
	Json7 = create_single_json("1.07", "16"),
    NewState7 = do_add_data(Json7, NewState6),
	
	?assertEqual([[6]], NewState7#state.matches),
	?assertEqual(0, NewState7#state.position),
	?assertEqual({Json7, [<<"GOOG">>,1.07,16]}, dict:fetch(6, NewState7#state.results)),
	
	%% Should reset as this should not fire
	Json8 = create_single_json("0.97", "16"),
    NewState8 = do_add_data(Json8, NewState7),
	
	?assertEqual([[]], NewState8#state.matches),
	?assertEqual(0, NewState8#state.position),
	?assertEqual({Json8, []}, dict:fetch(7, NewState8#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a two second standard window.  Adds some data
%% 		then simulates ticking the clock a couple of times.  The match list and results
%% 		dict should be emptied.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
timed_do_add_data_standard_consecutive_clock_tick_no_fire_test() ->
	QueryParameters = [{numberOfMatches, 5}, {windowSize, 2}, {windowType, time}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, InitialState),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(0, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),

    ok = timer:sleep(1000),

	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, clock_tick(NewState)),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(1, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	ok = timer:sleep(1000),

	Json3 = create_single_json("1.03", "12"),
	
    NewState3 = do_add_data(Json3, clock_tick(NewState2)),
	?assertEqual([[0,1,2]], NewState3#state.matches),
	?assertEqual(0, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	ok = timer:sleep(1000),

	Json4 = create_single_json("1.04", "13"),
	
    NewState4 = do_add_data(Json4, clock_tick(NewState3)),
	?assertEqual([[1,2,3]], NewState4#state.matches),
	?assertEqual(1, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
	
	%% Check that only three elements are left in the dict.
	?assertEqual(3, dict:size(NewState4#state.results)),
	
	ok = timer:sleep(1000),
	
	NewState5 = clock_tick(NewState4),
	?assertEqual([[2,3]], NewState5#state.matches).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a two second standard window.  Adds some data
%% 		then simulates ticking the clock a couple of times.  The match list and results
%% 		dict should be emptied.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
timed_do_add_data_standard_consecutive_clock_tick_no_fire_empty_test() ->
	QueryParameters = [{numberOfMatches, 5}, {windowSize, 2}, {windowType, time}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, clock_tick(InitialState)),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),

	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(1, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
	
    NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[0,1,2]], NewState3#state.matches),
	?assertEqual(1, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
	
    NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[0,1,2,3]], NewState4#state.matches),
	?assertEqual(1, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
		
	ok = timer:sleep(1000), %% 1 second
	
	NewState5 = clock_tick(NewState4),
	?assertEqual([[0,1,2,3]], NewState5#state.matches),
	
	ok = timer:sleep(1000), %% 2 second
	
	NewState6 = clock_tick(NewState5),
	
	ok = timer:sleep(1000), %% 3 seconds
	
	NewState7 = clock_tick(NewState6),
	?assertEqual([[]], NewState7#state.matches),
	?assertEqual(0, dict:size(NewState7#state.results)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc A test that creates a two second standard window.  Adds some data
%% 		then simulates ticking the clock a couple of times but the query fires.  
%% 		The match list and results dict should be emptied.
%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
timed_do_add_data_standard_consecutive_clock_tick_fire_test() ->
	QueryParameters = [{numberOfMatches, 5}, {windowSize, 2}, {windowType, time}],
	InitialState = create_initial_state(QueryParameters, create_standard_row_function(), create_reduce_function()),
	
	Json1 = create_single_json("1.01", "10"),
	
    NewState = do_add_data(Json1, clock_tick(InitialState)),
	?assertEqual([[0]], NewState#state.matches),
	?assertEqual(1, NewState#state.position),
	?assertEqual({Json1, [<<"GOOG">>,1.01,10]}, dict:fetch(0, NewState#state.results)),

	Json2 = create_single_json("1.02", "11"),
	
    NewState2 = do_add_data(Json2, NewState),
	?assertEqual([[0,1]], NewState2#state.matches),
	?assertEqual(1, NewState2#state.position),
	?assertEqual({Json2, [<<"GOOG">>,1.02,11]}, dict:fetch(1, NewState2#state.results)),
	
	Json3 = create_single_json("1.03", "12"),
	
    NewState3 = do_add_data(Json3, NewState2),
	?assertEqual([[0,1,2]], NewState3#state.matches),
	?assertEqual(1, NewState3#state.position),
	?assertEqual({Json3, [<<"GOOG">>,1.03,12]}, dict:fetch(2, NewState3#state.results)),
	
	Json4 = create_single_json("1.04", "13"),
	
    NewState4 = do_add_data(Json4, NewState3),
	?assertEqual([[0,1,2,3]], NewState4#state.matches),
	?assertEqual(1, NewState4#state.position),
	?assertEqual({Json4, [<<"GOOG">>,1.04,13]}, dict:fetch(3, NewState4#state.results)),
		
	ok = timer:sleep(1000), %% 1 second
	
	NewState5 = clock_tick(NewState4),
	?assertEqual([[0,1,2,3]], NewState5#state.matches),
	
	ok = timer:sleep(1000), %% 2 second
	
	NewState6 = clock_tick(NewState5),
	
	ok = timer:sleep(1000), %% 3 seconds
	
	%% Should now fire
	NewState7 = clock_tick(NewState6),
	?assertEqual([[]], NewState7#state.matches),
	?assertEqual(0, dict:size(NewState7#state.results)),
	
	ok = timer:sleep(1000), %% 2 second
	
	%% should stay empty
	NewState8 = clock_tick(NewState7),
	?assertEqual([[]], NewState8#state.matches),
	?assertEqual(0, dict:size(NewState8#state.results)).