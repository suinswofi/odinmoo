// LambdaCore -- teach the core's display verbs to paint through $ansi (themes/cga/ansi.moo
// must have been applied first). Each @program below is the stock verb with only its
// output calls changed; the logic is untouched. Where a line was already right, it is
// repeated verbatim so a diff against the original core shows exactly what moved.

// ---- $string_utils: padding must measure VISIBLE width, or every column that holds a
// colored name drifts by the width of its markup (@who, inventory columns, ...).

@program $string_utils:left
"$string_utils:left(string,width[,filler])";
"";
"Assures that <string> is at least <width> characters wide.  Returns <string> if it is at least that long, or else <string> followed by enough filler to make it that wide. If <width> is negative and the length of <string> is greater than the absolute value of <width>, then the <string> is cut off at <width>.";
"";
"The <filler> is optional and defaults to \" \"; it controls what is used to fill the resulting string when it is too short.  The <filler> is replicated as many times as is necessary to fill the space in question.";
"Widths are VISIBLE widths: color markup (see $ansi) is not counted, and a string that has to be cut is cut by visible width too ($ansi:cut).";
{text, len, ?fill = " "} = args;
abslen = abs(len);
out = tostr(text);
if ((vis = ansi_len(out)) < abslen)
return out + this:space(vis - abslen, fill);
else
return (len > 0) ? out | $ansi:cut(out, abslen);
endif
.

@program $string_utils:right
"$string_utils:right(string,width[,filler])";
"";
"Assures that <string> is at least <width> characters wide.  Returns <string> if it is at least that long, or else <string> preceded by enough filler to make it that wide. If <width> is negative and the length of <string> is greater than the absolute value of <width>, then <string> is cut off at <width> from the right.";
"";
"The <filler> is optional and defaults to \" \"; it controls what is used to fill the resulting string when it is too short.  The <filler> is replicated as many times as is necessary to fill the space in question.";
"Widths are VISIBLE widths: color markup (see $ansi) is not counted, and a string that has to be cut is cut by visible width too ($ansi:cut).";
{text, len, ?fill = " "} = args;
abslen = abs(len);
out = tostr(text);
if ((lenout = ansi_len(out)) < abslen)
return this:space(abslen - lenout, fill) + out;
elseif ((len > 0) || (lenout == length(out)))
return (len > 0) ? out | out[($ - abslen) + 1..$];
else
"...cutting from the left of a string that carries color markup: drop the markup, since a code that fell in the cut part would be lost anyway...";
out = ansi_strip(out);
return out[($ - abslen) + 1..$];
endif
.

@program $string_utils:center
"$string_utils:center(string,width[,lfiller[,rfiller]])";
"";
"Assures that <string> is at least <width> characters wide.  Returns <string> if it is at least that long, or else <string> preceded and followed by enough filler to make it that wide.  If <width> is negative and the length of <string> is greater than the absolute value of <width>, then the <string> is cut off at <width>.";
"";
"The <lfiller> is optional and defaults to \" \"; it controls what is used to fill the left part of the resulting string when it is too short.  The <rfiller> is optional and defaults to the value of <lfiller>; it controls what is used to fill the right part of the resulting string when it is too short.  In both cases, the filler is replicated as many times as is necessary to fill the space in question.";
"Widths are VISIBLE widths: color markup (see $ansi) is not counted, and a string that has to be cut is cut by visible width too ($ansi:cut).";
{text, len, ?lfill = " ", ?rfill = lfill} = args;
out = tostr(text);
abslen = abs(len);
if ((vis = ansi_len(out)) < abslen)
return (this:space((abslen - vis) / 2, lfill) + out) + this:space(((abslen - vis) + 1) / -2, rfill);
else
return (len > 0) ? out | $ansi:cut(out, abslen);
endif
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
.

// ---- Looking at things

@program $root_class:look_self
desc = this:description();
if (desc)
player:tell_lines(desc);
else
player:tell($ansi:meta("You see nothing special."));
endif
.

@program $room:look_self
{?brief = 0} = args;
player:tell($ansi:title(this:title()));
if (!brief)
pass();
endif
this:tell_contents(setremove(this:contents(), player), this.ctype);
.

@program $room:tell_contents
{contents, ctype} = args;
if ((!this.dark) && (contents != {}))
if (ctype == 0)
player:tell($ansi:heading("Contents:"));
for thing in (contents)
player:tell("  ", $ansi:name(thing, thing:title()));
endfor
elseif (ctype == 1)
for thing in (contents)
if (is_player(thing))
player:tell($ansi:name(thing, thing:titlec()), " ", $gender_utils:get_conj("is", thing), " here.");
else
player:tell("You see ", $ansi:name(thing, thing:title()), " here.");
endif
endfor
elseif (ctype == 2)
player:tell("You see ", $ansi:names(contents), " here.");
elseif (ctype == 3)
players = things = {};
for x in (contents)
if (is_player(x))
players = {@players, x};
else
things = {@things, x};
endif
endfor
if (things)
player:tell("You see ", $ansi:names(things), " here.");
endif
if (players)
player:tell($ansi:names(players, 1), (length(players) == 1) ? " " + $gender_utils:get_conj("is", players[1]) | " are", " here.");
endif
endif
endif
.

@program $player:look_self
player:tell($ansi:title(this:titlec()));
pass();
if (!(this in connected_players()))
player:tell($ansi:meta($gender_utils:pronoun_sub("%{:He} %{!is} sleeping.", this)));
elseif ((idle = idle_seconds(this)) < 60)
player:tell($ansi:meta($gender_utils:pronoun_sub("%{:He} %{!is} awake and %{!looks} alert.", this)));
else
time = $string_utils:from_seconds(idle);
player:tell($ansi:meta(tostr($gender_utils:pronoun_sub("%{:He} %{!is} awake, but %{!has} been staring off into space for ", this), time, ".")));
endif
if (c = this:contents())
this:tell_contents(c);
endif
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
cx = tostr(" ", $ansi:name(thing, thing:title()));
if (ansi_len(cx) > half)
longear = {@longear, cx};
else
gear = {@gear, cx};
endif
endfor
player:tell_lines($string_utils:columnize(gear, 2, width));
player:tell_lines(longear);
endif
.

@program $player:i
if (c = player:contents())
this:tell_contents(c);
else
player:tell($ansi:meta("You are empty-handed."));
endif
.

// ---- Talking

@program $room:say
try
player:tell("You say, ", $ansi:quote(argstr));
this:announce($ansi:player(player.name), " ", $gender_utils:get_conj("says", player), ", ", $ansi:quote(argstr));
except (ANY)
"Don't really need to do anything but ignore the idiot who has a bad :tell";
endtry
.

@program $room:emote
if ((argstr != "") && (argstr[1] == ":"))
this:announce_all($ansi:player(player.name), argstr[2..length(argstr)]);
else
this:announce_all($ansi:player(player.name), " ", argstr);
endif
.

@program $player:whisper
this:tell($ansi:player(player.name), " whispers, ", $ansi:quote(dobjstr));
player:tell("You whisper, ", $ansi:quote(dobjstr), " to ", $ansi:player(this.name), ".");
.

@program $player:page
nargs = length(args);
if (nargs < 1)
player:notify(tostr("Usage: ", verb, " <player> [with <message>]"));
return;
endif
who = $string_utils:match_player(args[1]);
if ($command_utils:player_match_result(who, args[1])[1])
return;
elseif (who in this.gaglist)
player:tell("You have ", who:title(), " @gagged.  If you paged ", $gender_utils:get_pronoun("o", who), ", ", $gender_utils:get_pronoun("s", who), " wouldn't be able to answer you.");
return;
endif
"for pronoun_sub's benefit...";
dobj = who;
iobj = player;
header = $ansi:meta(player:page_origin_msg());
text = "";
if (nargs > 1)
if ((args[2] == "with") && (nargs > 2))
msg_start = 3;
else
msg_start = 2;
endif
msg = $string_utils:from_list(args[msg_start..nargs], " ");
text = tostr($ansi:player($string_utils:pronoun_sub($string_utils:index_delimited(header, player.name) ? "%S" | "%N")), " ", $string_utils:pronoun_sub("%<pages>"), ", ", $ansi:quote(msg));
endif
result = text ? who:receive_page(header, text) | who:receive_page(header);
if (result == 2)
"not connected";
player:tell($ansi:meta((typeof(msg = who:page_absent_msg()) == STR) ? msg | $string_utils:pronoun_sub("%n is not currently logged in.", who)));
else
player:tell($ansi:meta(who:page_echo_msg()));
endif
.

// ---- Coming and going

@program $exit:announce_msg
":announce_msg(place, what, msg)";
"  announce msg in place (except to what). Prepend with what:title if it isn't part of the string";
msg = args[3];
what = args[2];
title = what:titlec();
if (!$string_utils:index_delimited(msg, title))
msg = tostr(title, " ", msg);
endif
"The whole line is quiet grey except the name of whoever is moving, in their own color; the meta color is re-entered right after the name so the rest of the sentence stays grey.";
args[1]:announce_all_but({what}, $ansi:meta(strsub(msg, title, tostr($ansi:name(what, title), $ansi.meta[1]))));
.

@program $exit:move
set_task_perms(caller_perms());
what = args[1];
"if ((what.location != this.source) || (!(this in this.source.exits)))";
"  player:tell(\"You can't go that way.\");";
"  return;";
"endif";
unlocked = this:is_unlocked_for(what);
if (unlocked)
this.dest:bless_for_entry(what);
endif
if (unlocked && this.dest:acceptable(what))
start = what.location;
if (msg = this:leave_msg(what))
what:tell_lines(msg);
endif
what:moveto(this.dest);
if (what.location != start)
"Don't print oleave messages if WHAT didn't actually go anywhere...";
this:announce_msg(start, what, (this:oleave_msg(what) || this:defaulting_oleave_msg(what)) || "has left.");
endif
if (what.location == this.dest)
"Don't print arrive messages if WHAT didn't really end up there...";
if (msg = this:arrive_msg(what))
what:tell_lines(msg);
endif
this:announce_msg(what.location, what, this:oarrive_msg(what) || "has arrived.");
endif
else
if (msg = this:nogo_msg(what))
what:tell_lines(msg);
else
what:tell($ansi:error("You can't go that way."));
endif
if (msg = this:onogo_msg(what))
this:announce_msg(what.location, what, msg);
endif
endif
.

@program $room:go
if ((!args) || (!(dir = args[1])))
player:tell($ansi:error("You need to specify a direction."));
return E_INVARG;
elseif (valid(exit = player.location:match_exit(dir)))
exit:invoke();
if (length(args) > 1)
old_room = player.location;
"Now give objects in the room we just entered a chance to act.";
suspend(0);
if (player.location == old_room)
"player didn't move or get moved while we were suspended";
player.location:go(@listdelete(args, 1));
endif
endif
elseif (exit == $failed_match)
player:tell($ansi:error(tostr("You can't go that way (", dir, ").")));
else
player:tell($ansi:error(tostr("I don't know which direction `", dir, "' you mean.")));
endif
.

@program $room:e
set_task_perms((caller_perms() == #-1) ? player | caller_perms());
exit = this:match_exit(verb);
if (valid(exit))
exit:invoke();
elseif (exit == $failed_match)
player:tell($ansi:error("You can't go that way."));
else
player:tell($ansi:error(tostr("I don't know which direction `", verb, "' you mean.")));
endif
.

@program $room:here_huh
":here_huh(verb,args)  -- room-specific :huh processing.  This should return 1 if it finds something interesting to do and 0 otherwise; see $command_utils:do_huh.";
"For the generic room, we check for the case of the caller specifying an exit for which a corresponding verb was never defined.";
set_task_perms(caller_perms());
if (args[2] || ($failed_match == (exit = this:match_exit(verb = args[1]))))
"... okay, it's not an exit.  we give up...";
return 0;
elseif (valid(exit))
exit:invoke();
else
"... ambiguous exit ...";
player:tell($ansi:error(tostr("I don't know which direction `", verb, "' you mean.")));
endif
return 1;
.

@program $room:@exits
if (!$perm_utils:controls(valid(caller_perms()) ? caller_perms() | player, this))
player:tell($ansi:error("Sorry, only the owner of a room may list its exits."));
elseif (this.exits == {})
player:tell($ansi:meta("This room has no conventional exits."));
else
try
for exit in (this.exits)
try
player:tell($ansi:name(exit, exit.name), " ", $ansi:punct(tostr("(", exit, ")")), " leads to ", valid(exit.dest) ? $ansi:place(exit.dest.name) | "???", " ", $ansi:punct(tostr("(", exit.dest, ")")), " via {", $string_utils:from_list(exit.aliases, ", "), "}.");
except (ANY)
player:tell($ansi:error("Bad exit or missing .dest property:  "), $string_utils:nn(exit));
continue exit;
endtry
endfor
except (E_TYPE)
player:tell($ansi:error("Bad .exits property. This should be a list of exit objects. Please fix this."));
endtry
endif
.

@program $room:confunc
if ((((cp = caller_perms()) == player) || $perm_utils:controls(cp, player)) || (caller == this))
"Need the first check because guests don't control themselves";
this:look_self(player.brief);
this:announce($ansi:name(player, player:titlec()), " ", $ansi:meta($string_utils:pronoun_sub("%<has> connected.", player)));
endif
.

// (Disconnected players sit in $limbo, so this -- not $room:confunc -- is what actually
// announces most connections; $player_start:disfunc likewise for the pop on disconnect.)
@program $limbo:confunc
(caller == #0) || raise(E_PERM);
{who} = args;
"this:eject(who)";
if (!$recycler:valid(home = who.home))
clear_property(who, "home");
home = who.home;
if (!$recycler:valid(home))
home = who.home = $player_start;
endif
endif
"Modified 08-22-98 by TheCat to foil people who manually set their home to places they shouldn't.";
if ((!home:acceptable(who)) || (!home:accept_for_abode(who)))
home = $player_start;
endif
try
move(who, home);
except (ANY)
move(who, $player_start);
endtry
who.location:announce_all_but({who}, $ansi:name(who, who.name), " ", $ansi:meta("has connected."));
.

@program $player_start:disfunc
"Copied from The Coat Closet (#11):disfunc by Haakon (#2) Mon May  8 10:41:04 1995 PDT";
if ((((cp = caller_perms()) == (who = args[1])) || $perm_utils:controls(cp, who)) || (caller == this))
"need the first check since guests don't control themselves";
if (who.home == this)
move(who, $limbo);
this:announce($ansi:meta("You hear a quiet popping sound; "), $ansi:name(who, who.name), " ", $ansi:meta("has disconnected."));
else
pass(who);
endif
endif
.

@program $room:disfunc
if ((((cp = caller_perms()) == player) || $perm_utils:controls(cp, player)) || (caller == this))
this:announce($ansi:name(player, player:titlec()), " ", $ansi:meta($string_utils:pronoun_sub("%<has> disconnected.", player)));
"need the first check since guests don't control themselves";
if (!$object_utils:isa(player, $guest))
"guest disfuncs are handled by $guest:disfunc. Don't add them here";
$housekeeper:move_players_home(player);
endif
endif
.

// ---- When the parser gives up

@program $command_utils:object_match_failed
"Usage: object_match_failed(object, string)";
"Prints a message if string does not match object.  Generally used after object is derived from a :match_object(string).";
{match_result, string} = args;
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
player:(tell)($ansi:error(tostr("I see no \"", string, "\" here.")));
elseif (match_result == $ambiguous_match)
player:(tell)($ansi:error(tostr("I don't know which \"", string, "\" you mean.")));
elseif (!valid(match_result))
player:(tell)($ansi:error(tostr(match_result, " does not exist.")));
else
return 0;
endif
return 1;
.

@program $command_utils:do_huh
":do_huh(verb,args)  what :huh should do by default.";
{verb, args} = args;
if ($perm_utils:controls(caller_perms(), player) || (caller_perms() == player))
this.feature_task = {task_id(), verb, args, argstr, dobj, dobjstr, prepstr, iobj, iobjstr};
endif
set_task_perms(cp = caller_perms());
notify = $perm_utils:controls(cp, player) ? "notify" | "tell";
if (verb == "")
"should only happen if a player types backslash";
player:(notify)($ansi:error("I don't understand that."));
return;
endif
if (player:my_huh(verb, args))
"... the player found something funky to do ...";
elseif (caller:here_huh(verb, args))
"... the room found something funky to do ...";
elseif (player:last_huh(verb, args))
"... player's second round found something to do ...";
elseif (dobj == $ambiguous_match)
if (iobj == $ambiguous_match)
player:(notify)($ansi:error(tostr("I don't understand that (\"", dobjstr, "\" and \"", iobjstr, "\" are both ambiguous names).")));
else
player:(notify)($ansi:error(tostr("I don't understand that (\"", dobjstr, "\" is an ambiguous name).")));
endif
elseif (iobj == $ambiguous_match)
player:(notify)($ansi:error(tostr("I don't understand that (\"", iobjstr, "\" is an ambiguous name).")));
else
player:(notify)($ansi:error("I don't understand that."));
player:my_explain_syntax(caller, verb, args) || (caller:here_explain_syntax(caller, verb, args) || this:explain_syntax(caller, verb, args));
endif
.

// ---- @who

@program $code_utils:show_who_listing
":show_who_listing(players[,more_players])";
" prints a listing of the indicated players.";
" For players in the first list, idle/connected times are shown if the player is logged in, otherwise the last_disconnect_time is shown.  For players in the second list, last_disconnect_time is shown, no matter whether the player is logged in.";
{plist, ?more_plist = {}} = args;
idles = itimes = offs = otimes = {};
argstr = dobjstr = iobjstr = prepstr = "";
for p in (more_plist)
if (!valid(p))
caller:notify(tostr(p, " <invalid>"));
elseif (typeof(t = `p.last_disconnect_time ! E_PROPNF') == INT)
if (!(p in offs))
offs = {@offs, p};
otimes = {@otimes, {-t, -t, p}};
endif
elseif (is_player(p))
caller:notify(tostr(p.name, " (", p, ") ", (t == E_PROPNF) ? "is not a $player." | "has a garbled .last_disconnect_time."));
else
caller:notify(tostr(p.name, " (", p, ") is not a player."));
endif
endfor
for p in (plist)
if (p in offs)
elseif (!valid(p))
caller:notify(tostr(p, " <invalid>"));
elseif (typeof(i = `idle_seconds(p) ! ANY') != ERR)
if (!(p in idles))
idles = {@idles, p};
itimes = {@itimes, {i, connected_seconds(p), p}};
endif
elseif (typeof(t = `p.last_disconnect_time ! E_PROPNF') == INT)
offs = {@offs, p};
otimes = {@otimes, {-t, -t, p}};
elseif (is_player(p))
caller:notify(tostr(p.name, " (", p, ") not logged in.", (t == E_PROPNF) ? "  Not a $player." | "  Garbled .last_disconnect_time."));
else
caller:notify(tostr(p.name, " (", p, ") is not a player."));
endif
endfor
if (!(idles || offs))
return 0;
endif
idles = $list_utils:sort_alist(itimes);
offs = $list_utils:sort_alist(otimes);
"...";
"... calculate widths (visible widths -- names and locations carry color markup)...";
"...";
headers = {"Player name", @idles ? {"Connected", "Idle time"} | {"Last disconnect time", ""}, "Location"};
total_width = `caller:linelen() ! ANY => 0' || 79;
max_name = total_width / 4;
name_width = length(headers[1]);
names = locations = {};
for lst in ({@idles, @offs})
$command_utils:suspend_if_needed(0);
p = lst[3];
namestr = tostr($ansi:player(p.name[1..min(max_name, $)]), " ", $ansi:punct(tostr("(", p, ")")));
name_width = max(ansi_len(namestr), name_width);
names = {@names, namestr};
if (typeof(wlm = `p.location:who_location_msg(p) ! ANY') != STR)
wlm = valid(p.location) ? p.location.name | tostr("** Nowhere ** (", p.location, ")");
endif
locations = {@locations, $ansi:place(wlm)};
endfor
time_width = 3 + (offs ? 12 | length("59 minutes"));
before = {0, w1 = 3 + name_width, w2 = w1 + time_width, w2 + time_width};
"...";
"...print headers...";
"...";
su = $string_utils;
tell1 = headers[1];
tell2 = su:space(tell1, "-");
for j in [2..4]
tell1 = su:left(tell1, before[j]) + headers[j];
tell2 = su:left(tell2, before[j]) + su:space(headers[j], "-");
endfor
caller:notify($ansi:fade(tell1[1..min($, total_width)], "rule"));
caller:notify($ansi:fade(tell2[1..min($, total_width)], "rule"));
"...";
"...print lines...";
"...";
active = 0;
for i in [1..total = (ilen = length(idles)) + length(offs)]
if (i <= ilen)
lst = idles[i];
if (lst[1] < (5 * 60))
active = active + 1;
endif
l = {names[i], su:from_seconds(lst[2]), su:from_seconds(lst[1]), locations[i]};
else
lct = offs[i - ilen][3].last_connect_time;
ldt = offs[i - ilen][3].last_disconnect_time;
ctime = `caller:ctime(ldt) ! ANY => 0' || ctime(ldt);
l = {names[i], (lct <= time()) ? ctime | "Never", "", locations[i]};
if ((i == (ilen + 1)) && idles)
caller:notify(su:space(before[2]) + $ansi:meta("------- Disconnected -------"));
endif
endif
tell1 = l[1];
for j in [2..4]
tell1 = su:left(tell1, before[j]) + l[j];
endfor
caller:notify($ansi:cut(tell1, total_width));
if ($command_utils:running_out_of_time())
if ($login:is_lagging())
"Check lag two ways---global lag, but we might still fail due to individual lag of the queue this runs in, so check again later.";
caller:notify(tostr("Plus ", total - i, " other players (", total, " total; out of time and lag is high)."));
return;
endif
now = time();
suspend(0);
if ((time() - now) > 10)
caller:notify(tostr("Plus ", total - i, " other players (", total, " total; out of time and lag is high)."));
return;
endif
endif
endfor
"...";
"...epilogue...";
"...";
caller:notify("");
if (total == 1)
active_str = ", who has" + ((active == 1) ? "" | " not");
else
if (active == total)
active_str = (active == 2) ? "s, both" | "s, all";
elseif (active == 0)
active_str = "s, none";
else
active_str = tostr("s, ", active);
endif
active_str = tostr(active_str, " of whom ha", (active == 1) ? "s" | "ve");
endif
caller:notify($ansi:meta(tostr("Total: ", total, " player", active_str, " been active recently.")));
return total;
.

// ---- The login screen: a BBS-door style banner around the stock text.

;$login.welcome_message = {"", "|05-=|13-=|15-=|13-=|05-=|08---------------------------------------------------------|05-=|13-=|15-=|13-=|05-=|DF", "", "  |15W|11elcom|03e|DF to the |15L|11ambdaCor|03e|DF database.", "", "  Type '|13connect wizard|DF' to log in.", "", "  |08You will probably want to change this text and the output of the `help' command, which are stored in $login.welcome_message and $login.help_message, respectively.|DF", "", "|05-=|13-=|15-=|13-=|05-=|08---------------------------------------------------------|05-=|13-=|15-=|13-=|05-=|DF", ""};
