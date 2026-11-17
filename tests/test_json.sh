# json_escape / json_unescape — the build/decode pair of the wire protocol.
# The command and tool results may contain any bytes; these must round-trip.
. "$(dirname "$0")/lib.sh"

load_fn json_escape json_unescape

# --- json_escape: individual escapes ---
assert_eq 'plain'            'hello'              "$(json_escape 'hello')"
assert_eq 'double quote'     'a\"b'               "$(json_escape 'a"b')"
assert_eq 'backslash'        'a\\b'               "$(json_escape 'a\b')"
assert_eq 'backslash+quote'  'a\\\\\"b'           "$(json_escape 'a\\"b')"
assert_eq 'newline'          'a\nb'               "$(json_escape $'a\nb')"
assert_eq 'tab'              'a\tb'               "$(json_escape $'a\tb')"
assert_eq 'carriage return'  'a\rb'               "$(json_escape $'a\rb')"
assert_eq 'backspace'        'a\bb'               "$(json_escape $'a\x08b')"
assert_eq 'form feed'        'a\fb'               "$(json_escape $'a\x0cb')"
assert_eq 'vertical tab'     'a\u000bb'           "$(json_escape $'a\x0bb')"
# \uXXXX escape: 4 representatives across the 0x01–0x1f range (all hit the
# same printf '\u%04x' path).
assert_eq 'ctrl-a'           'a\u0001b'           "$(json_escape $'a\x01b')"
assert_eq 'ctrl-z'           'a\u001ab'           "$(json_escape $'a\x1ab')"
assert_eq 'esc'              'a\u001bb'           "$(json_escape $'a\x1bb')"
assert_eq 'ctrl-_'            'a\u001fb'           "$(json_escape $'a\x1fb')"
assert_eq 'empty'            ''                   "$(json_escape '')"

# --- json_unescape: individual escapes ---
assert_eq 'unescape plain'        'hello'          "$(json_unescape 'hello')"
assert_eq 'unescape quote'        'a"b'            "$(json_unescape 'a\"b')"
assert_eq 'unescape backslash'    'a\b'            "$(json_unescape 'a\\b')"
assert_eq 'unescape newline'      $'a\nb'          "$(json_unescape 'a\nb')"
assert_eq 'unescape tab'          $'a\tb'          "$(json_unescape 'a\tb')"
assert_eq 'unescape cr'           $'a\rb'          "$(json_unescape 'a\rb')"
assert_eq 'unescape backspace'    $'a\x08b'        "$(json_unescape 'a\bb')"
assert_eq 'unescape form feed'    $'a\x0cb'        "$(json_unescape 'a\fb')"
assert_eq 'unescape slash'        'a/b'            "$(json_unescape 'a\/b')"
assert_eq 'unescape vt'           $'a\x0bb'        "$(json_unescape 'a\u000bb')"
assert_eq 'unescape ctrl-a'       $'a\x01b'        "$(json_unescape 'a\u0001b')"
assert_eq 'unescape ctrl-z'       $'a\x1ab'        "$(json_unescape 'a\u001ab')"
assert_eq 'unescape esc'          $'a\x1bb'        "$(json_unescape 'a\u001bb')"
assert_eq 'unescape ctrl-_'       $'a\x1fb'        "$(json_unescape 'a\u001fb')"
assert_eq 'unescape nul dropped'  'ab'             "$(json_unescape 'a\u0000b')"
assert_eq 'unescape u-lf'         $'a\nb'          "$(json_unescape 'a\u000ab')"
assert_eq 'unescape u-cr'         $'a\rb'          "$(json_unescape 'a\u000db')"
assert_eq 'unescape u-a'          'aAb'            "$(json_unescape 'a\u0041b')"
assert_eq 'unescape u-0x80'       $'a\xc2\x80b'    "$(json_unescape 'a\u0080b')"
assert_eq 'unescape u-0x100'      $'a\xc4\x80b'    "$(json_unescape 'a\u0100b')"
assert_eq 'unescape u-0x7ff'      $'a\xdf\xbfb'    "$(json_unescape 'a\u07ffb')"
assert_eq 'unescape u-cjk'        $'a\xe4\xb8\xadb' "$(json_unescape 'a\u4e2db')"
assert_eq 'unescape u-euro'       $'\xe2\x82\xac'  "$(json_unescape '\u20ac')"
assert_eq 'unescape surrogate pair' $'a\xf0\x9f\x98\x80b' "$(json_unescape 'a\ud83d\ude00b')"
assert_eq 'unescape lone high surr' $'a\xef\xbf\xbdX' "$(json_unescape 'a\ud83dX')"
assert_eq 'unescape lone low surr'  $'a\xef\xbf\xbdb' "$(json_unescape 'a\ude00b')"
assert_eq 'unescape bad hex'       'ab'             "$(json_unescape 'a\uZZZZb')"
assert_eq 'unescape bad hex'      'ab'             "$(json_unescape 'a\u00zzb')"
assert_eq 'unescape unknown esc'  'a\qb'          "$(json_unescape 'a\qb')"
assert_eq 'unescape empty'        ''               "$(json_unescape '')"

# --- round-trip: escape then unescape must give back the original ---
# (strings must not end in a newline: command substitution strips it)
for s in 'hello' 'a"b\c' $'a\nb\tc\r' $'a\x01b\x07c\x1f' 'café' $'caf\xc3\xa9' \
         'back\\slash "and" quotes' $'a\x0bb\x08c\x0cd' 'unicode: \u00e9\u00fc'; do
	assert_eq "round-trip: $(printf '%s' "$s" | od -An -c | tr -d '\n')" \
		"$s" "$(json_unescape "$(json_escape "$s")")"
done

# --- json_unescape: escapes straddling the internal 512-byte window ---
for pad in 500 506 508 510 511 512; do
	p=$(head -c $pad /dev/zero | tr '\0' a)
	for esc in '\n' '\u00e9' '\ud83d\ude00' '\\' '\"'; do
		want=$(json_unescape "$esc"; printf x)
		got=$(json_unescape "$p$esc$p"; printf x)
		assert_eq "window pad=$pad esc=$esc" "$p${want%x}$p" "${got%x}"
	done
done

# --- json_unescape: a large string with many escapes stays fast (it was
#     quadratic: ~20 s for 2000 escapes). Bound: 10 s. ---
big=""; i=0
while [ $i -lt 2000 ]; do big="${big}line of text\\n"; i=$((i + 1)); done
t0=$(date +%s); out=$(json_unescape "$big"; printf x); t1=$(date +%s)
assert_eq 'many escapes: decoded size' 26000 "$(( ${#out} - 1 ))"
assert_true 'many escapes: under 10s' [ "$((t1 - t0))" -lt 10 ]

summary
