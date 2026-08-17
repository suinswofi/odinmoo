// JHCore -- teach the core's display verbs to paint through $ansi (themes/cga/ansi.moo must
// have been applied first). Each @program below is the stock verb with only its output calls
// changed; the logic is untouched, and unchanged lines are repeated verbatim so a diff
// against the original core shows exactly what moved.
//
// JHCore differs from LambdaCore in two ways that shape this file: names are produced by the
// :name(flags) machinery (articles, capitalization, idle suffixes), so color is applied at the
// display hooks that sit on top of it (:name_for_tell_contents / :namec_for_look_self)
// rather than inside :name itself; and speech goes through $pronoun_sub's compiled message
// lists ($room.say_msg), where the color pieces become literal segments of the message.

// ---- $string_utils: padding must measure VISIBLE width, or every column that holds a
// colored name drifts by the width of its markup (@who, inventory columns, ...).

@program $string_utils:left
"$string_utils:left(string,width[,filler]) -- pad (or, for negative width, cut) string to width. Widths are VISIBLE widths: color markup (see $ansi) is not counted, and a string that has to be cut is cut by visible width too ($ansi:cut).";
{text, len, ?fill = " "} = args;
abslen = abs(len);
out = tostr(text);
if ((vis = ansi_len(out)) < abslen)
return out + this:space(vis - abslen, fill);
else
return (len > 0) ? out | $ansi:cut(out, abslen);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $string_utils:right
"$string_utils:right(string,width[,filler]) -- see :left; widths are visible widths.";
{text, len, ?fill = " "} = args;
abslen = abs(len);
out = tostr(text);
if ((vis = ansi_len(out)) < abslen)
return this:space(abslen - vis, fill) + out;
else
return (len > 0) ? out | $ansi:cut(out, abslen);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $string_utils:center
"$string_utils:center(string,width[,lfiller[,rfiller]]) -- see :left; widths are visible widths.";
{text, len, ?lfill = " ", ?rfill = lfill} = args;
out = tostr(text);
abslen = abs(len);
if ((vis = ansi_len(out)) < abslen)
return (this:space((abslen - vis) / 2, lfill) + out) + this:space(((abslen - vis) + 1) / -2, rfill);
else
return (len > 0) ? out | $ansi:cut(out, abslen);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $string_utils:columnize
"columnize (items, n [, width]) - Turn a one-column list of items into an n-column list. 'width' is the last character position that may be occupied; it defaults to a standard screen width. Example: To tell the player a list of numbers in three columns, do 'player:tell_lines ($string_utils:columnize ({1, 2, 3, 4, 5, 6, 7}, 3));'.";
"Items may carry color markup (see $ansi); columns are laid out by visible width.";
{items, n, ?width = 79} = args;
height = ((length(items) + n) - 1) / n;
items = {@items, @$list_utils:make((height * n) - length(items), "")};
colwidths = {};
for col in [1..n - 1]
colwidths = listappend(colwidths, 1 - (((width + 1) * col) / n));
endfor
result = {};
for row in [1..height]
line = tostr(items[row]);
for col in [1..n - 1]
line = tostr(this:left(line, colwidths[col]), " ", items[row + (col * height)]);
endfor
line = $ansi:cut(line, width);
result = listappend(result, line);
endfor
return result;
"Metadata 202106";
.

// ---- Names, where the core displays them

@program $root_class:name_for_tell_contents
"name_for_tell_contents / namec_for_tell_contents: how this object is named in a room's or container's contents listing.  Painted by kind through $ansi:name (players, exits, rooms, things each have a color) -- the color goes on here, on top of :name(), so :name() itself stays plain for matching, capitalizing and everything else.";
return $ansi:name(this, this:name((verb[5] == "c") ? "ivc" | "iv"));
"Metadata 202106";
.

@program $room:namec_for_look_self
"Capitalize all words according to english title rules, then paint as a title.";
return $ansi:title($english:titleize(pass(@args)));
"Metadata 202106";
.

// ---- Looking at things

@program $root_class:look_self
desc = this:description(@args);
if (desc)
player:tell_lines(desc);
else
player:tell($ansi:meta("You see nothing special."));
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $room:look_self
brief = args && args[1];
player:tell(this:namec_for_look_self(brief));
things = this:visible_of(setremove(this:contents(), player));
integrate = {};
if (this.integration_enabled)
for i in (things)
if (this:ok_to_integrate(i) && ((!brief) || (!is_player(i))))
integrate = {@integrate, i};
things = setremove(things, i);
endif
endfor
"for i in (this:obvious_exits(player))";
for i in (this:exits())
if (this:ok_to_integrate(i))
integrate = setadd(integrate, i);
"changed so prevent exits from being integrated twice in the case of doors and the like";
endif
endfor
endif
if (!brief)
desc = this:description(integrate);
if (desc)
player:tell_lines(desc);
else
player:tell($ansi:meta("You see nothing special."));
endif
endif
"there's got to be a better way to do this, but.";
if (topic = this:topic_msg())
if (0)
this.topic_sign:show_topic();
else
player:tell(this.topic_sign:integrate_room_msg());
endif
endif
"this:tell_contents(things, this.ctype);";
this:tell_contents(things);
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $player:look_self
integrate = {};
dontintegrate = {};
if (visible = this:visible_of(this.contents))
for i in (visible)
if (this:ok_to_integrate(i))
integrate = {@integrate, i};
else
dontintegrate = {@dontintegrate, i};
endif
endfor
endif
desc = this:description(integrate);
if (desc)
player:tell_lines(desc);
else
player:tell($ansi:meta("You see nothing special."));
endif
player:tell($ansi:meta(this:desc_idle_msg()));
if (dontintegrate)
this:tell_contents(dontintegrate);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $player:tell_contents
c = args[1];
if (c)
longear = {};
gear = {};
width = player:linelen();
half = width / 2;
player:tell($ansi:heading("Carrying:"));
for thing in (c)
cx = tostr(" ", thing:name_for_tell_contents());
if (ansi_len(cx) > half)
longear = {@longear, cx};
else
gear = {@gear, cx};
endif
endfor
player:tell_lines($string_utils:columnize(gear, 2, width));
player:tell_lines(longear);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $player:i
if (player.contents)
this:tell_contents(player.contents);
else
player:tell($ansi:meta("You are empty-handed."));
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

// ---- Talking. $room.say_msg is a compiled $pronoun_sub message: literal strings in it pass
// straight through, so the theme's pieces are spliced in around the name / verb / speech
// slots (baked from $ansi's properties when this script runs).

;m = $room.say_msg; $room.say_msg = {m[1], m[2], $ansi.player[1], m[3], $ansi.reset + m[4], m[5], tostr(", ", $ansi.punct[1], "\"", $ansi.speech[1]), m[7], tostr($ansi.punct[1], "\"", $ansi.reset)}; return $room.say_msg;

@program $room:emote
name = $ansi:player(`player:dnamec() ! ANY');
if ((argstr != "") && (argstr[1] == ":"))
this:announce_all(name, text = argstr[2..$]);
else
this:announce_all(name, " ", text = argstr);
endif
this:broadcast_event_emote(argstr);
return 0 && "Automatically Added Return";
"Metadata 202106";
"Last-Modify: {869623859, \"Erik\", #74, \"JHM\"}";
.

@program $player:whisper
if (this.location != player.location)
player:tell($ansi:error(tostr(this:dnamec(), " isn't here.")));
elseif (this in connected_players())
msg = $pronoun_sub.("two-letter"):parse("%nD %n:(whispers) to %td, \"%$d\"");
"Splice the theme's colors around the name, target and speech slots of the compiled message (`|' is the two-letter parser's line separator, so the codes can't go in the format string itself).";
msg = {msg[1], msg[2], $ansi.player[1], msg[3], $ansi.reset + msg[4], msg[5], msg[6] + $ansi.player[1], msg[7], tostr($ansi.reset, ", ", $ansi.punct[1], "\"", $ansi.speech[1]), msg[9], tostr($ansi.punct[1], "\"", $ansi.reset)};
parties = $pronoun_sub:parse_parties({}, this);
for o in (setadd({player}, this))
$you:say(msg, o, parties);
endfor
return;
this:tell(player:dnamec(), " whispers, \"", dobjstr, "\"");
player:tell("You whisper, \"", dobjstr, "\" to ", this:dname(), ".");
else
player:tell($ansi:meta(tostr("You begin to whisper to ", this:dname(), ", but then notice that ", this:ps(), this:verb_sub("'s/'re"), " asleep.")));
endif
"Copied from generic player (#6):whisper by the folding couch (#437) Mon Jun 12 15:58:27 1995 EDT";
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $player:page
nargs = length(args);
if (!args)
player:notify(tostr("Usage: ", verb, " <player> [with] [<message>]"));
return;
endif
who = player:my_match_player(args[1]);
if ($command_utils:player_match_result(who, args[1])[1])
return;
elseif (who:absent_for_page())
"player:notify(tostr($string_utils:pronoun_sub((typeof(msg = who:page_absent_msg()) == STR) ? msg | \"%N is not currently logged in.\", who)));";
player:notify($ansi:meta(tostr($string_utils:pronoun_sub(who:page_absent_msg(), who))));
return;
endif
header = $ansi:meta(player:page_origin_msg());
text = "";
msg = "";
if (nargs > 1)
if ((args[2] == "with") && (nargs > 2))
msg_start = 3;
else
msg_start = 2;
endif
msg = $string_utils:from_list(args[msg_start..nargs], " ");
text = tostr($ansi:player($string_utils:index_delimited(header, player:name()) ? player:psc() | player:inamec()), " ", player:verb_sub("pages"), ", ", $ansi:quote(msg));
feedback = tostr("You page ", $ansi:name(who, who:dname()), ", ", $ansi:quote(msg));
else
if (header == "")
text = tostr($ansi:player(player:inamec()), " ", player:verb_sub("pages"), " you.");
endif
feedback = tostr("You page ", $ansi:name(who, who:dname()), ".");
endif
who:receive_page(@setremove({header, text}, ""));
if (extra_feedback = who:page_echo_msg(msg))
player:notify_lines({feedback, $ansi:meta(tostr(extra_feedback))});
else
player:notify(feedback);
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
"Last-Modify: {993469409, \"Xplat\", #4014, \"Waterpoint\"}";
.

// ---- Coming and going

@program $exit:move
what = args[1];
start = what.location;
if (start != this.source)
what:tell($ansi:error("You can't go that way."));
return;
endif
unlocked = this:is_unlocked_for(what);
if (typeof(dest = this.dest) == LIST)
dest = dest[1]:create(listdelete(dest, 1));
endif
if (unlocked)
dest:bless_for_entry(what);
endif
start:broadcast_event_move_by_exit_attempted(what, this);
dest:broadcast_event_move_by_exit_attempted(what, this);
if (unlocked && dest:accept(what))
if (msg = this:leave_msg(what))
what:tell_lines(msg);
endif
what:moveto(dest);
start:broadcast_event_move_by_exit_completed(what, this);
what.location:broadcast_event_move_by_exit_completed(what, this);
if ((what.location != start) || (dest == start))
"Don't print oleave messages if WHAT didn't actually go anywhere...";
"Unless the exit is actually a loop...";
msg = this:oleave_msg(what) || this:defaulting_oleave_msg(what);
start:announce_all_but({what}, this.prefix_name ? $ansi:name(what, what:dnamec()) + " " | "", $ansi:meta(msg || (what:verb_sub("has") + " left.")));
endif
if (what.location == dest)
"Don't print arrive messages if WHAT didn't really end up there...";
if (msg = this:arrive_msg(what))
what:tell_lines(msg);
endif
msg = this:oarrive_msg(what) || this:defaulting_oarrive_msg(what);
what.location:announce_all_but({what}, this.prefix_name ? $ansi:name(what, what:inamec()) + " " | "", $ansi:meta(msg || (what:verb_sub("has") + " arrived.")));
this:sweep_for_followers(what);
endif
else
start:broadcast_event_move_by_exit_failed(what, this);
what.location:broadcast_event_move_by_exit_failed(what, this);
if (msg = this:nogo_msg(what))
what:tell_lines(msg);
else
what:tell($ansi:error("You can't go that way."));
endif
if (msg = this:onogo_msg(what))
what.location:announce_all_but({what}, this.prefix_name ? $ansi:name(what, what:dnamec()) + " " | "", $ansi:meta(msg));
endif
endif
"Copied from generic exit (#7):move by Ken (#75) Tue Nov  7 19:12:28 1995 CST";
"Copied from generic exit (#7):move(old) by Ken (#75) Tue Nov  7 19:32:34 1995 CST";
return 0 && "Automatically Added Return";
"Metadata 202106";
.

@program $room:e
exit_name = verb;
if (args)
exit_name = tostr(exit_name, " ", argstr);
endif
exit = this:match_exit(exit_name);
if (valid(exit))
exit:invoke();
elseif (exit == $failed_match)
results = this:broadcast_event_move_in_unknown_direction({player}, exit_name);
if (!results)
player:tell($ansi:error("You can't go that way."));
endif
else
player:tell($ansi:error(tostr("There's more than one way to go in the direction `", verb, "'.")));
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
"Last-Modify: {983475732, \"Xplat\", #4014, \"Waterpoint\"}";
.

@program $room:@exits
"Usage: @exits [obvious]";
who = valid(caller_perms()) ? caller_perms() | player;
obvious = (args && (length(args) == 1)) && (index("obvious", args[1]) == 1);
if (args && (!obvious))
$command_utils:explain_syntax(this, verb, args);
return E_ARGS;
endif
if (obvious || (!this:can_read_exits(who)))
exits = this:obvious_exits();
names = {};
for exit in (exits)
names = {@names, $ansi:name(exit, exit:dname())};
endfor
player:tell($ansi:heading("Obvious exits:"), "  ", $string_utils:english_list(names, "none"), ".");
"player:tell(\"Sorry, only the owner of a room may list its exits.\");";
elseif (!(exits = this:exits()))
player:tell($ansi:meta("This room has no conventional exits."));
else
for exit in (exits)
"xplat 2002.01.31 -- Erik's version of the 'nowhere' thing didn't really work, so I'm trying something slightly more elaborate.";
room = `exit.dest ! E_INVIND, E_PROPNF => #-1';
room_name = valid(room) ? $ansi:place($string_utils:dname_and_number(room)) | "nowhere";
exit_namec = valid(exit) ? $ansi:name(exit, $string_utils:dnamec_and_number(exit)) | tostr("An invalid exit (", exit, ")");
player:tell(exit_namec, " leads to ", room_name, " via {", $string_utils:from_list(`exit.aliases ! E_INVIND => {}', ", "), "}.");
endfor
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
"Last-Modify: {1012665094, \"splat\", #3024, \"JHM (for core)\"}";
.

@program $room:confunc
if (!(caller in {#0, this}))
return E_PERM;
endif
this:look_self(player:brief());
this:announce($ansi:name(player, player:inamec()), " ", $ansi:meta(tostr(player:verb_sub("has"), " connected.")));
return 0 && "Automatically Added Return";
"Metadata 202106";
.

// (On connect JHCore's $limbo moves the player to the connect point and announces
// $limbo.connect_msg -- another compiled $pronoun_sub message, spliced like say_msg above.)
;m = $limbo.connect_msg; $limbo.connect_msg = {m[1], m[2], $ansi.player[1], m[3], tostr($ansi.reset, m[4], $ansi.meta[1]), m[5], m[6] + $ansi.reset}; return $limbo.connect_msg;

@program $room:reconfunc
if (caller in {this, #0})
fork (0)
this:look_self(player:brief());
endfork
this:announce($ansi:name(player, player:dnamec()), " ", $ansi:meta("has reconnected."));
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
"Last-Modify: {1019688825, \"Xythian\", #199, \"Waterpoint\"}";
.

@program $room:disfunc
this:announce($ansi:name(args[1], args[1]:dnamec()), " ", $ansi:meta(tostr(args[1]:verb_sub("has"), " disconnected.")));
return 0 && "Automatically Added Return";
"Metadata 202106";
.

// ---- When the parser gives up

@program $command_utils:object_match_failed
"Usage: object_match_failed(object, string)";
"Prints a message if string does not match object.  Generally used after object is derived from a :match_object(string).";
match_result = args[1];
string = args[2];
tell = $perm_utils:controls(caller_perms(), player) ? "notify" | "tell";
if ((index(string, "#") == 1) && ($code_utils:toobj(string) != E_TYPE))
"...avoid the `I don't know which `#-2' you mean' message...";
if (!valid(match_result))
player:(tell)($ansi:error(tostr(string, " does not exist.")));
endif
return !valid(match_result);
elseif (match_result == $nothing)
player:(tell)($ansi:error("You must give the name of some object."));
elseif (match_result == $failed_match)
player:(tell)($ansi:error(tostr("You see no \"", string, "\" here.")));
elseif (match_result == $ambiguous_match)
player:(tell)($ansi:error(tostr("You haven't specified which \"", string, "\" you mean.")));
elseif (!valid(match_result))
player:(tell)($ansi:error(tostr(match_result, " does not exist.")));
else
return 0;
endif
return 1;
"Metadata 202106";
.

@program $command_utils:do_huh
":do_huh(verb,args)  what :huh should do by default.";
set_task_perms(cp = caller_perms());
verb = args[1];
args = args[2];
bad = "That is not a valid command";
notify = $perm_utils:controls(cp, player) ? "notify" | "tell";
if (valid(player.location))
dobj = player.location:match_object(dobjstr);
iobj = player.location:match_object(iobjstr);
endif
if (player:my_huh(verb, args))
"... the player found something funky to do ...";
elseif (caller:here_huh(verb, args))
"... the room found something funky to do ...";
elseif (this:extra_huh(verb, args))
"... we found something on dobj or iobj";
elseif (player:last_huh(verb, args))
"... player's second round found something to do ...";
"elseif ($mistake_tracker:handle_failed_command(player, verb, argstr, dobjstr, prepstr, iobjstr, dobj, iobj))";
"... experimental mistake learner found something to do ...";
elseif (dobj == $ambiguous_match)
"... from here on, it's all error-reporting.";
if (iobj == $ambiguous_match)
player:(notify)($ansi:error(tostr(bad, " (\"", dobjstr, "\" and \"", iobjstr, "\" are both ambiguous names).")));
else
player:(notify)($ansi:error(tostr(bad, " (\"", dobjstr, "\" is an ambiguous name).")));
endif
elseif (iobj == $ambiguous_match)
player:(notify)($ansi:error(tostr(bad, " (\"", iobjstr, "\" is an ambiguous name).")));
else
(player:my_explain_syntax(caller, verb, args) || (caller:here_explain_syntax(caller, verb, args) || this:explain_syntax(caller, verb, args))) || player:(notify)($ansi:error(bad + "."));
endif
return 0 && "Automatically Added Return";
"Metadata 202106";
.

// ---- @who ($who_utils builds its own columns; names and locations get their colors at the
// source, the justifier learns to measure visible width, and the two title lines get the
// dim-bright-dim gradient.)

@program $who_utils:_get_name
"_get_name(list of people)";
"return {column width, {list of names}}";
p = args[1];
return $ansi:player(p:inamec());
"Metadata 202106";
.

@program $who_utils:_get_location
p = args[1];
if (typeof(m = p.location:who_location_msg(p)) != STR)
m = " ** Nowhere **";
endif
return $ansi:place(m);
"Metadata 202106";
.

@program $who_utils:left_just
"Left Justify/truncate string at specified width";
"left_just(string, width, filler)";
"Widths are visible widths: color markup (see $ansi) is not counted, and a string that has to be cut is cut by visible width too ($ansi:cut).";
{string, width, ?filler = " "} = args;
string = $ansi:cut(string, width);
vis = ansi_len(string);
return (vis < width) ? string + $string_utils:space(width - vis, filler) | string;
"Metadata 202106";
"Last-Modify: {835905466, \"Erik\", #74, \"JHM\"}";
.

@program $who_utils:_get_columns
columns = args[1];
people = args[2];
sort = args[3];
data = {};
s = {};
id = {};
linelen = player:linelen() || 79;
for i in (people)
this:sin();
data = {@data, $ansi:cut((v = this:_get_line(i, columns, sort))[2], linelen)};
s = {@s, v[1]};
id = {@id, v[3]};
endfor
$command_utils:suspend_if_needed(0);
return {id, s, data};
"Metadata 202106";
"Last-Modify: {835905430, \"Erik\", #74, \"JHM\"}";
.

@program $who_utils:_build_title
"_build_title(column names, columns)";
"construct title lines";
columns = args[1];
titles = {};
linelen = player:linelen() || 79;
for i in (columns)
titles = {@titles, this.column_titles[i[1] in this.valid_columns]};
endfor
titlel = "";
linel = "";
csep = this.csep;
lengths = $list_utils:slice(columns, 2);
for i in [1..length(lengths)]
if (lengths[i] == "short")
lengths[i] = 4;
elseif (lengths[i] == "long")
lengths[i] = 10;
endif
endfor
for i in [1..length(titles)]
titlel = (titlel + this:left_just(titles[i], lengths[i])) + csep;
linel = (linel + this:left_just($string_utils:space(length(titles[i]), "-"), lengths[i])) + csep;
endfor
return {$ansi:fade($ansi:cut($string_utils:trimr(titlel), linelen), "rule"), $ansi:fade($ansi:cut($string_utils:trimr(linel), linelen), "rule")};
"Metadata 202106";
.

@program $who_utils:show_who_listing
":show_who_listing(players, [[, moreplayers], spam])";
"name:20  location:20  doing:30  last_disconnect:28";
connected = {};
if (length(args) > 1)
disconnected = args[2];
else
disconnected = {};
endif
if (length(args) > 2)
spamv = "tell";
spam = toobj(args[3]);
else
spamv = "notify";
spam = caller;
endif
columns = this:_columns(player:who_option("columns") || $player:who_option("columns"));
sort = player:who_option("order") || $player:who_option("order");
asc = player:who_option("ascending");
for i in (args[1])
this:sin();
if (!$object_utils:isa(i, $Player))
spam:(spamv)(tostr($string_utils:nn(i), " is not a $player."));
elseif (typeof(idle_seconds(i)) != ERR)
connected = setadd(connected, i);
else
disconnected = setadd(disconnected, i);
endif
endfor
this:sin();
active = 0;
inactive = 0;
strings = {};
if ((!connected) && (!disconnected))
return;
endif
if (connected)
strings = (v = this:_get_columns(columns, connected, sort))[3];
sortd = v[2];
idles = v[1];
this:sin();
strings = this:("_sort_by_" + sort)(sortd, strings, asc);
disconnected && (strings = {@strings, $ansi:meta("        " + $string_utils:space(15, "-"))});
for i in (idles)
inactive = inactive + (i > 300);
endfor
active = active + (length(connected) - inactive);
endif
this:sin();
if (disconnected)
cd = this:_columns({"name", "location", "last_disconnect"});
stringsd = (v = this:_get_columns(cd, disconnected, "last_disconnect"))[3];
stringsd = this:_sort_by_last_disconnect(v[2], stringsd, 0);
inactive = inactive + length(disconnected);
strings = {@strings, @stringsd};
endif
if (connected)
title = this:_build_title(columns);
else
title = this:_build_title(cd, datad, widthsd);
endif
spam:(spamv + "_lines")(title);
spam:(spamv + "_lines")(strings);
total = inactive + active;
if (total == 1)
spam:(spamv + "_lines")({"", $ansi:meta(tostr("Total: ", total, " person, who has", active ? "" | " not", " been active recently."))});
else
spam:(spamv + "_lines")({"", $ansi:meta(tostr("Total: ", total, " people, ", active ? (active == total) ? (active == 2) ? "both" | "all" | active | ((total == 2) ? "neither" | "none"), " of ", (active == 1) ? "whom has" | "whom have", " been active recently."))});
endif
return total;
"Metadata 202106";
.

// ---- The login screen: a BBS-door style banner around the stock text.

;$login.welcome_message = {"", "|05-=|13-=|15-=|13-=|05-=|08---------------------------------------------------------|05-=|13-=|15-=|13-=|05-=|DF", "", "  |15W|11elcom|03e|DF to the |15J|11HCor|03e|DF database.", "  |08Extracted August 27, 2002 (under LambdaMOO 1.8.1)|DF", "", "  Type '|13connect wizard|DF' to log in.", "", "  |08You will probably want to change this text, which is stored in $login.welcome_message.|DF", "", "  |08Before you do, though, please read `help core-copyright' (linked to `help copyright') for the exceedingly broad copyright on JHCore.|DF", "", "  |08You will also want to read `help getting-started' for some more information about starting a JHCore MOO.|DF", "", "|05-=|13-=|15-=|13-=|05-=|08---------------------------------------------------------|05-=|13-=|15-=|13-=|05-=|DF", ""};
