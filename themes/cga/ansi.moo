// $ansi -- the CGA "palette 1" theme object: cyan / magenta / white on black, in the style
// of the old BBS door games. Shared by every core; the per-core scripts next to this one
// only teach the core's own display verbs to call it.
//
// Convention: verb code never writes color codes itself. It asks $ansi for a ROLE --
//   $ansi:title(text)    room names, the name line of anything you `look` at (white->cyan fade)
//   $ansi:heading(text)  section heads: "Contents:", "Carrying:"                (bright magenta)
//   $ansi:exit(text)     exit names                                       (bright cyan)
//   $ansi:thing(text)    object names in lists                            (bright cyan)
//   $ansi:place(text)    room names mentioned in passing (@who, @exits)   (cyan)
//   $ansi:player(text)   player names: who's here, who said what          (bright magenta)
//   $ansi:speech(text)   the words inside quotes                          (white)
//   $ansi:punct(text)    quote marks, brackets, "(#123)"                  (magenta)
//   $ansi:meta(text)     status/system chatter, footers, idle notes       (dark grey)
//   $ansi:error(text)    "I don't understand that", "You can't go that way" (bright magenta)
// -- plus $ansi:name(obj [, text]) which picks player/exit/place/thing by what obj is,
// $ansi:names(objs) for an english list of those, $ansi:quote(text) for `"text"` with the
// quotes in punct and the words in speech, $ansi:rule([width [, char]]) for a faded bar,
// $ansi:fade(text, "rule") to run that same dim-bright-dim gradient across a whole line
// (table headers, banners) -- the one place a fade across several words reads as intended --
// and $ansi:cut(text, width) to truncate to a VISIBLE width without losing the markup
// (what $string_utils:left and friends use when a colored column overflows).
//
// Every role is a property holding a RAMP: a list of |NN pipe-codes (see the server's
// ansi package). One code = solid color; several = the text is split into that many
// pieces, each in the next color -- the "fade" effect. Retheming is just changing these
// properties; the verbs that call $ansi never change. Pipe-codes rather than %-codes on
// purpose: MOO's pronoun_sub already owns `%N`/`%n` and friends.

// (create() charges the owner's ownership_quota even for wizards, and JHCore's wizard carries
// a negative one that its $quota_utils reads as "unlimited" but the builtin reads as "none" --
// lend a quota of 1 for the create() and put the original back.)
;add_property(#0, "ansi", #-1, {player, "r"});
;q = `player.ownership_quota ! ANY => E_PROPNF'; if (typeof(q) == INT) player.ownership_quota = 1; endif; #0.ansi = create(parent($string_utils), player); if (typeof(q) == INT) player.ownership_quota = q; endif;
;$ansi.name = "ANSI theme (CGA)";
;$ansi.aliases = {"ansi", "ANSI theme (CGA)"};
;$ansi.description = "The color theme: cyan, magenta and white on black, like a CGA monitor running a BBS door game. Verb code asks this object for a role ($ansi:title, :heading, :exit, :thing, :place, :player, :speech, :punct, :meta, :error, :name, :names, :quote, :rule) instead of writing color codes itself; each role is a property holding a list of |NN pipe-codes, so the whole look can be changed by editing those properties.";
;add_property($ansi, "reset", "|DF", {player, "r"});
;add_property($ansi, "title", {"|15", "|11", "|03"}, {player, "r"});
;add_property($ansi, "heading", {"|13"}, {player, "r"});
;add_property($ansi, "exit", {"|11"}, {player, "r"});
;add_property($ansi, "thing", {"|11"}, {player, "r"});
;add_property($ansi, "place", {"|03"}, {player, "r"});
;add_property($ansi, "player", {"|13"}, {player, "r"});
;add_property($ansi, "speech", {"|15"}, {player, "r"});
;add_property($ansi, "punct", {"|05"}, {player, "r"});
;add_property($ansi, "meta", {"|08"}, {player, "r"});
;add_property($ansi, "error", {"|13"}, {player, "r"});
;add_property($ansi, "rule", {"|05", "|13", "|15", "|13", "|05"}, {player, "r"});
;add_property($ansi, "roles", {"title", "heading", "exit", "thing", "place", "player", "speech", "punct", "meta", "error", "rule"}, {player, "r"});

@verb $ansi:fade this none this rxd
@program $ansi:fade
":fade(text, ramp) => text painted with the ramp's colors spread across it, reset at the end.";
"ramp is either a list of |NN pipe-codes or the name of one of this object's role properties (see .roles).";
"One code paints the whole text; N codes split the text into N pieces, one per color, which is the fade effect.  Text shorter than the ramp gets one character per color, from the start of the ramp.";
{text, ramp} = args;
text = tostr(text);
if (typeof(ramp) == STR)
ramp = `this.(ramp) ! E_PROPNF => {}';
endif
if (typeof(ramp) == STR)
ramp = {ramp};
endif
if ((!text) || (!ramp))
return text;
endif
len = length(text);
if (length(ramp) == 1)
return tostr(ramp[1], text, this.reset);
endif
chunks = min(length(ramp), len);
out = "";
for i in [1..chunks]
out = tostr(out, ramp[i], text[(((i - 1) * len) / chunks) + 1..(i * len) / chunks]);
endfor
return out + this.reset;
.

@verb $ansi:"title heading exit thing place player speech punct meta error" this none this rxd
@program $ansi:title
":title(text), :heading(text), :exit(text), :thing(text), :place(text), :player(text), :speech(text), :punct(text), :meta(text), :error(text)";
"=> text painted in this theme's colors for that role.  Each role is a property on this object holding a ramp; see :fade.";
return this:fade(args ? args[1] | "", verb);
.

@verb $ansi:name this none this rxd
@program $ansi:name
":name(obj [, text]) => text (default obj:title()) painted according to what obj is: a player, an exit, a room, or some other thing.";
{what, ?text = 0} = args;
if (typeof(text) != STR)
text = valid(what) ? tostr(`what:title() ! ANY => what.name') | tostr(what);
endif
if (!valid(what))
role = "meta";
elseif (is_player(what))
role = "player";
elseif ($object_utils:isa(what, $exit))
role = "exit";
elseif ($object_utils:isa(what, $room))
role = "place";
else
role = "thing";
endif
return this:fade(text, role);
.

@verb $ansi:names this none this rxd
@program $ansi:names
":names(objs [, capitalize]) => an english list (\"a, b, and c\") of the objects' titles, each colored by :name.  A true second argument capitalizes the first one, like $string_utils:title_listc.";
{objs, ?cap = 0} = args;
out = {};
for o in (objs)
if (valid(o))
t = tostr(`((cap && (!out)) ? o:titlec() | o:title()) ! ANY => o.name');
else
t = tostr(o);
endif
out = {@out, this:name(o, t)};
endfor
return $string_utils:english_list(out);
.

@verb $ansi:quote this none this rxd
@program $ansi:quote
":quote(text) => text wrapped in double quotes, the quotes in the punct color and the words in the speech color.";
return tostr(this.punct[1], "\"", this.speech[1], args ? args[1] | "", this.punct[1], "\"", this.reset);
.

@verb $ansi:rule this none this rxd
@program $ansi:rule
":rule([width [, char]]) => a horizontal rule of width characters (default: the player's line length, or 79) in the rule fade.";
{?width = 0, ?char = "-"} = args;
width = abs(width) || (abs(`player:linelen() ! ANY => 0') || 79);
bar = "";
while (length(bar) < width)
bar = bar + char;
endwhile
return this:fade(bar[1..width], "rule");
.

@verb $ansi:cut this none this rxd
@program $ansi:cut
":cut(text, width) => text cut down to at most width VISIBLE characters, keeping its color markup intact; ends with a reset if anything was cut, so no color leaks past the cut.";
"Recognizes the server's |NN / |DF / |DB pipe-codes and %-codes as zero-width (%% is one visible percent sign) -- the same rules ansi_len() uses.";
{text, width} = args;
text = tostr(text);
if (ansi_len(text) <= width)
return text;
endif
out = "";
seen = 0;
i = 1;
n = length(text);
while ((i <= n) && (seen < width))
c = text[i];
if ((((c == "|") && ((i + 2) <= n)) && index("0123456789", text[i + 1])) && (index("0123456789", text[i + 2]) && (toint(text[i + 1..i + 2]) <= 31)))
out = out + text[i..i + 2];
i = i + 3;
elseif ((((c == "|") && ((i + 2) <= n)) && index("dD", text[i + 1], 1)) && index("fFbB", text[i + 2], 1))
out = out + text[i..i + 2];
i = i + 3;
elseif (((c == "%") && ((i + 1) <= n)) && index("xrgybmcwXRGYBMCWhn", text[i + 1], 1))
out = out + text[i..i + 1];
i = i + 2;
elseif (((c == "%") && ((i + 1) <= n)) && (text[i + 1] == "%"))
out = out + "%%";
i = i + 2;
seen = seen + 1;
else
out = out + c;
i = i + 1;
seen = seen + 1;
endif
endwhile
return out + this.reset;
.

@verb $ansi:strip this none this rxd
@program $ansi:strip
":strip(text) => text with all color markup removed (the ansi_strip() builtin, for callers that don't want to depend on it directly).";
return ansi_strip(tostr(@args));
.

@verb $ansi:len this none this rxd
@program $ansi:len
":len(text) => the visible width of text, ignoring color markup (the ansi_len() builtin).";
return ansi_len(tostr(@args));
.

// Self-check: dbscript prints these so a broken theme is obvious in the build log.
;return $ansi:fade("The First Room", "title");
;return $ansi:names({$room, $player, $exit, $thing});
;return $ansi:rule(20, "=");
;return {$ansi:cut("|13Wizard|DF (#2) and more", 8), $ansi:cut("plain text", 5), $ansi:cut("%%r%rred", 3)};
