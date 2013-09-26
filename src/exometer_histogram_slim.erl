%% MUST ONLY BE INVOKED THROUGH THE EXOMETER_PROBE.ERL MODULE.
%% NOT MULTI-PROCESSS SAFE.
-module(exometer_histogram_slim).
-behaviour(exometer_entry).
-behaviour(exometer_probe).

%% exometer_entry callbacks
-export([new/3,
	 delete/3,
	 get_value/3,
	 update/4,
	 reset/3,
	 sample/3,
	 setopts/4]).

%% exometer_probe callbacks
-export([probe_init/3,
	 probe_terminate/1,
	 probe_get_value/1,
	 probe_update/2,
	 probe_reset/1,
	 probe_sample/1,
	 probe_setopts/2,
	 probe_handle_call/3,
	 probe_handle_cast/2,
	 probe_handle_info/2,
	 probe_code_change/3]).

-export([average_sample/3,
	 average_transform/2]).

-include("exometer.hrl").

-record(st, {name,
	     slide = undefined, %%
	     slot_period = 1000, %% msec
	     time_span = 60000, %% msec
	     percentiles = [ 99.0 ], %% Which percentages to calculate
	     opts = []}).

%%
%% exometer_entry callbacks
%%
new(Name, Type, Options) ->
    Pid = spawn_opt(fun() ->
			   {ok, S} = probe_init(Name, Type, Options),
			   loop(S)
		   end, [{min_heap_size, 100000},
			 {priority, high}]),
    exometer_admin:monitor(Name, Pid),
    {ok, Pid}.

probe_init(Name, _Type, Options) ->
    erlang:monitor(process, exometer_sup),
    St = process_opts(#st {name = Name},
		      [{percentiles, [ 50, 75, 90, 95, 99, 999 ]},
		       {time_span, 60000},
		       {slot_period,100}] ++ Options),
    Slide = exometer_slot_slide:new(St#st.time_span,
				    St#st.slot_period,
				    fun average_sample/3,
				    fun average_transform/2),
    {ok, St#st{slide = Slide}}.

loop(S) ->
    receive
        {'DOWN', _, process, exometer_sup, _} ->
            exit(normal);
	{update, Value} ->
	    loop(probe_update(Value, S));
	{From, Ref, get_value} ->
	    From ! {Ref, probe_get_value(S)},
	    loop(S);
	reset ->
	    loop(probe_reset(S))
    end.

delete(Name, Type, Ref) when is_pid(Ref) ->
    exit(Ref, kill).

probe_terminate(_ModSt) ->
    ok.

get_value(Name, Type, Ref) ->
    MRef = erlang:monitor(process, Ref),
    Ref ! {self(), MRef, get_value},
    receive
	{MRef, Res} ->
	    Res;
	{'DOWN', MRef, _, _, _} ->
	    unavailable
    end.

probe_get_value(St) ->
    %% We need element count and sum of all elements to get mean value.
    Val = exometer_slot_slide:foldl(
	    fun({_TS, Val}, {Length, Total, List}) ->
		    { Length + 1, Total + Val, [ Val | List ]}
	    end,
	    {0, 0.0, []}, St#st.slide),
    {Length, Total, Lst} = Val,
    Sorted = lists:sort(Lst),

    %% Calc median. FIXME: Can probably be made faster.
    Median = case {Length, Length rem 2} of
	{0, _} -> %% No elements
	    0.0;
	{_, 0} ->    %% Even number with at least two elements.
		     %% Return average of two center elements
		     lists:sum(lists:sublist(Sorted,
					     trunc(Length / 2), 2)) / 2.0;

	{_, 1} ->    %% Odd number with at least one element.
		     %% Return center element
	    lists:nth(trunc(Length / 2) + 1, Sorted)
    end,
    Mean = case Length of
	       0 -> 0;
	       _ -> Total / Length
	   end,
    Items = [{min, 1}] ++
	[{P, perc(P / 100, Length) } || P <- St#st.percentiles] ++
	[{max, Length}],
    [Min|Rest] = pick_items(Sorted, 1, Items),
    [Min,
     {mean, Mean},
     {arithmetic_mean, Mean},
     {median, Median},
     {percentile, lists:keydelete(max,1,Rest)},
      lists:last(Rest)].


pick_items([H|_] = L, P, [{Tag,P}|Ps]) ->
    [{Tag,H} | pick_items(L, P, Ps)];

pick_items([_|T], P, Ps) ->
    pick_items(T, P+1, Ps);


pick_items([], _, Ps) ->
    [{Tag,0.0} || {Tag,_} <- Ps].

perc(P, Len) when P > 1.0 ->
    round((P / 10) * Len);

perc(P, Len) ->
    round(P * Len).


setopts(_Name, _Options, _Type, _Ref)  ->
    ok.

probe_setopts(_Opts, _St) ->
    error(unsupported).

update(Name, Value, Type, Ref) ->
    Ref ! {update, Value},
    ok.

probe_update(Value, St) ->
    Slide = exometer_slot_slide:add_element(Value, St#st.slide),
    St#st{slide = Slide}.


reset(Name, Type, Ref) ->
    Ref ! reset,
    ok.

probe_reset(St) ->
    St#st{slide = exometer_slot_slide:reset(St#st.slide)}.


sample(_Name, _Type, _Ref) ->
    { error, unsupported }.


probe_sample(_St) ->
    error(unsupported).

probe_handle_call(_, _, _) ->
    {ok, error}.

probe_handle_cast(_, _) ->
    ok.

probe_handle_info(_, _) ->
    ok.

probe_code_change(_From, ModSt, _Extra) ->
    {ok, ModSt}.

process_opts(St, Options) ->
    lists:foldl(
      fun
	  %% Sample interval.
	  ({time_span, Val}, St1) -> St1#st { time_span = Val };
	  ({slot_period, Val}, St1) -> St1#st { slot_period = Val };
	  ({percentiles, Val}, St1) -> St1#st { percentiles = Val };

	  %% Unknown option, pass on to State options list, replacing
	  %% any earlier versions of the same option.
	  ({Opt, Val}, St1) ->
	      St1#st{ opts = [ {Opt, Val}
			       | lists:keydelete(Opt, 1, St1#st.opts) ] }
      end, St, Options).

%% Simple sample processor that maintains an average
%% of all sampled values
average_sample(_TS, Val, undefined) ->
   {1, Val};

average_sample(_TS, Val, {Count, Total}) ->
    {Count + 1, Total + Val}.

%% If average_sample() has not been called for the current time slot,
%% then the provided state will still be 'undefined'
average_transform(_TS, undefined) ->
    0.0;

%% Return the calculated total for the slot and return it as the
%% element to be stored in the histogram.
average_transform(_TS, {Count, Total}) ->
    Total / Count. %% Return the sum of all counter increments received during this slot.
