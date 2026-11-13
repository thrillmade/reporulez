# shellcheck shell=bash disable=SC2016
# Sourced by bin/apply.sh and bin/apply-org.sh -- never run on its own.
#
# The one implementation of "compare a preset with a live ruleset, classify
# every difference, and decide what --apply alone may write". Both scripts
# call it, so the rules cannot drift between the org path and the repo path.
# The kinds (tightens / weakens / removes bypass), the two flags that permit
# the last two, and what counts as an unusable live read are documented in
# the header of bin/apply-org.sh and in docs/branch-policy.md.
#
# The caller provides ALLOW_WEAKENING and ALLOW_BYPASS_REMOVAL ("true" or
# "false"). Functions here print and return; the caller decides to exit.
# They set, for the caller to read: CLASSIFIED, TIGHTENS, WEAKENS,
# REMOVES_BYPASS, BLOCKED.

# Normalise both sides the same way: keep only what an apply sends, drop the
# actor_id GitHub ignores for OrganizationAdmin, and sort every array (rule,
# bypass, ref and merge-method order carry no meaning). A field absent on
# one side stays absent: nothing here fills in a default, so a missing key
# can never compare equal to null, [], {}, 0 or false.
RC_NORMALISE='
  with_entries(select(.key as $k | ["name","target","enforcement","conditions","rules","bypass_actors"] | index($k)))
  | if (.bypass_actors | type) == "array"
    then .bypass_actors |= map(if type == "object" and .actor_type == "OrganizationAdmin" then .actor_id = null else . end)
    else . end
  | walk(if type == "array" then sort else . end)'

# rc_preset_is_one_object <json>: exactly one JSON object with a non-empty
# string name. A second document after the first would be sent but never compared.
rc_preset_is_one_object() {
  printf '%s' "$1" | jq -se 'length == 1 and (.[0] | type == "object" and (.name | type) == "string" and .name != "")' >/dev/null 2>&1
}

# rc_extra_fields <json>: the preset's fields the comparison does not cover.
# A preset carrying one would send something never compared.
rc_extra_fields() {
  echo "$1" | jq -r 'keys - ["name","target","enforcement","conditions","rules","bypass_actors"] | join(", ")'
}

# rc_pr_bad <json>: values that cannot exist are an invalid preset, not a
# "tightening": no way to merge at all, or an approval count GitHub has no
# such setting for. Prints the reasons, empty when none.
rc_pr_bad() {
  echo "$1" | jq -r '
  [.rules[]? | select(type == "object" and .type == "pull_request") | .parameters? | select(type == "object")
   | (if has("allowed_merge_methods") and ((.allowed_merge_methods | type) != "array" or (.allowed_merge_methods | length) == 0)
        then "pull_request.allowed_merge_methods must be a non-empty list" else empty end),
     (if has("required_approving_review_count")
         and ((.required_approving_review_count | type) != "number"
              or .required_approving_review_count != (.required_approving_review_count | floor)
              or .required_approving_review_count < 0 or .required_approving_review_count > 10)
        then "pull_request.required_approving_review_count must be an integer from 0 to 10" else empty end)
  ] | join("; ")'
}

# rc_live_list <raw>: the live list as one compact JSON list of rulesets, or
# non-zero. --paginate may emit one JSON array per page; they are slurped
# into one. Empty, null, an object where a list belongs, or an entry without
# a numeric id and a string name is not a list.
rc_live_list() {
  printf '%s' "$1" | jq -cse '
    select(length > 0 and all(.[]; type == "array"))
    | add
    | select(all(.[]; type == "object" and (.id | type) == "number" and (.name | type) == "string"))' 2>/dev/null
}

# rc_near_names <list> <name>: live names that equal <name> once case,
# spaces, hyphens and underscores are ignored, but are not identical.
# --apply would otherwise create a near-duplicate beside one.
rc_near_names() {
  printf '%s' "$1" | jq -r --arg name "$2" '
    def fold: ascii_downcase | gsub("[\\s_-]+"; "");
    .[] | select(.name != $name and (.name | fold) == ($name | fold)) | "\(.name) (id=\(.id))"'
}

# rc_matching_ids <list> <name>: one id per line for live rulesets of that exact name.
rc_matching_ids() {
  printf '%s' "$1" | jq -r --arg name "$2" '.[] | select(.name == $name) | .id'
}

# rc_detail_ok <json> <id> <name>: the detail read is the ruleset asked for,
# with every field the comparison reads. A missing bypass_actors is not "no
# bypass": GitHub omits it for a caller who cannot administer the ruleset.
# The body is slurped, so a second JSON document behind the first is a
# failed read, not ignored.
rc_detail_ok() {
  printf '%s' "$1" | jq -se --argjson id "$2" --arg name "$3" '
    length == 1 and (.[0]
    | type == "object" and .id == $id and .name == $name
    and (.target | type) == "string" and (.enforcement | type) == "string"
    and (.conditions | type) == "object"
    and (.rules | type) == "array"
    and all(.rules[]; type == "object" and (.type | type) == "string")
    and (.bypass_actors | type) == "array"
    and all(.bypass_actors[]; type == "object" and (.actor_type | type) == "string" and (.bypass_mode | type) == "string"))' \
    >/dev/null 2>&1
}

# rc_normalise <json>: the sorted-key normalised form, on stdout.
rc_normalise() {
  echo "$1" | jq -S "$RC_NORMALISE"
}

# Classify every difference as tightens / weakens / removes bypass, one
# line each: "<kind><TAB><what>". Every comparator goes through
# each_difference, which walks the UNION of keys on both sides: a field it
# has no rule for is reported as weakens, never skipped, and a key absent
# on one side or of a different JSON type is weakens before any rule runs.
IFS= read -r -d '' RC_CLASSIFY_PROGRAM <<'JQ_PROGRAM' || true
def t(m): "tightens\t" + m;
def w(m): "weakens\t" + m;
def b(m): "removes bypass\t" + m;
def keyset($a; $b): [$a, $b] | map(keys) | add | unique;
def missing_from($a; $b): [$a[] | . as $x | select(any($b[]; . == $x) | not)];
def shown($o; $k): if $o | has($k) then $o[$k] | tojson else "(absent)" end;
# An actor's identity. An absent actor_id is its own identity, never null.
def akey: "\(.actor_type)/\(if has("actor_id") | not then "(absent)" elif .actor_id == null then "-" else .actor_id | tojson end)";
def mode_rank: if type == "string" then {"pull_request": 1, "always": 2, "exempt": 3}[.] else null end;
def enf_rank: if type == "string" then {"disabled": 0, "evaluate": 1, "active": 2}[.] else null end;
def add_rule_types: ["creation", "update", "deletion", "non_fast_forward", "required_linear_history",
  "required_signatures", "pull_request", "required_status_checks", "required_deployments"];
def pr_booleans: ["dismiss_stale_reviews_on_push", "require_code_owner_review", "require_last_push_approval",
  "required_review_thread_resolution", "require_extra_approval_for_unattributed_changes"];

# The one door every comparator goes through. For each key on either side:
# present on both with the same value is no difference. Absent on one side,
# or present with a different JSON type (null included), is weakens: absence
# is never read as an empty list, zero, false or {}, so it can never pass
# for "everything removed". Only a same-typed, non-equal pair reaches f, as
# {k, path, l, p}.
def each_difference($prefix; $l; $p; f):
  keyset($l; $p)[] as $k
  | "\($prefix)\($k)" as $path
  | if ($l | has($k)) and ($p | has($k)) and $l[$k] == $p[$k] then empty
    elif ($l | has($k) | not) or ($p | has($k) | not) or ($l[$k] | type) != ($p[$k] | type)
      then w("would change \($path) from \(shown($l; $k)) to \(shown($p; $k)) (absent on one side, or a different JSON type: no rule can show that tightens)")
    else {k: $k, path: $path, l: $l[$k], p: $p[$k]} | f end;

# Two arrays, already the same type: the preset may add entries (coverage grows), never drop one.
def grow_only($path; $l; $p):
  (missing_from($l; $p)[] | w("would remove \(.) from \($path)")),
  (missing_from($p; $l)[] | t("adds \(.) to \($path)"));
# Two arrays: the preset may drop entries (exclusions, allowances), never add one.
def shrink_only($path; $l; $p):
  (missing_from($p; $l)[] | w("would add \(.) to \($path)")),
  (missing_from($l; $p)[] | t("removes \(.) from \($path)"));
def bool_on($path; $l; $p):
  if $l == false and $p == true then t("turns \($path) on")
  else w("would change \($path) from \($l) to \($p)") end;
def bool_off($path; $l; $p):
  if $l == true and $p == false then t("turns \($path) off")
  else w("would change \($path) from \($l) to \($p)") end;

def target_condition($name; $l; $p):
  each_difference("conditions.\($name)."; $l; $p;
    if .k == "include" and (.l | type) == "array" then grow_only(.path; .l; .p)
    elif .k == "exclude" and (.l | type) == "array" then shrink_only(.path; .l; .p)
    else w("would change \(.path) (no rule for this field)") end);

def conditions($l; $p):
  each_difference("conditions."; $l; $p;
    if (.k == "ref_name" or .k == "repository_name") and (.l | type) == "object"
      then target_condition(.k; .l; .p)
    else w("would change \(.path) (no rule for this condition)") end);

def pull_request_params($l; $p):
  each_difference("pull_request."; $l; $p;
    if .k == "required_approving_review_count" and (.l | type) == "number" then
      if .p > .l then t("raises \(.path) from \(.l) to \(.p)")
      else w("would change \(.path) from \(.l) to \(.p)") end
    elif (.k as $k | any(pr_booleans[]; . == $k)) and (.l | type) == "boolean" then bool_on(.path; .l; .p)
    elif .k == "allowed_merge_methods" and (.l | type) == "array" then shrink_only(.path; .l; .p)
    else w("would change \(.path) (no rule for this parameter)") end);

def check_name: if type == "object" and has("context") then .context else tojson end;
def status_check_params($l; $p):
  each_difference("required_status_checks."; $l; $p;
    if .k == "strict_required_status_checks_policy" and (.l | type) == "boolean" then bool_on(.path; .l; .p)
    elif .k == "do_not_enforce_on_create" and (.l | type) == "boolean" then bool_off(.path; .l; .p)
    elif .k == "required_status_checks" and (.l | type) == "array" then
      (missing_from(.l; .p)[] | w("would remove or change required status check \(check_name)")),
      (missing_from(.p; .l)[] | t("adds required status check \(check_name)"))
    else w("would change \(.path) (no rule for this parameter)") end);

def rule_shape: all(.[]; type == "object" and (.type | type) == "string");
def rules($l; $p):
  if ($l | rule_shape | not) or ($p | rule_shape | not)
  then w("would change rules (a rule that is not an object with a string type: no rule for this shape)")
  elif ($l | map(.type) | unique | length) != ($l | length) or ($p | map(.type) | unique | length) != ($p | length)
  then w("a rule type appears more than once (no rule for comparing that)")
  else
    ( $l[] as $lr
      | ([$p[] | select(.type == $lr.type)] | first) as $pr
      | if $pr == null then w("would remove rule \($lr.type)")
        else each_difference("\($lr.type)."; $lr; $pr;
          if .k == "parameters" and (.l | type) == "object" then
            if $lr.type == "pull_request" then pull_request_params(.l; .p)
            elif $lr.type == "required_status_checks" then status_check_params(.l; .p)
            else w("would change \(.path) (no rule for this rule type)") end
          else w("would change \(.path) (no rule for this field)") end)
        end ),
    ( $p[] | .type as $t
      | select(any($l[]; .type == $t) | not)
      | if any(add_rule_types[]; . == $t) then t("adds rule \($t)")
        else w("would add rule \($t) (no rule for this rule type)") end )
  end;

def actor_shape: all(.[]; type == "object" and (.actor_type | type) == "string");
def bypass($l; $p):
  if ($l | actor_shape | not) or ($p | actor_shape | not)
  then w("would change bypass_actors (an actor that is not an object with a string actor_type: no rule for this shape)")
  elif ([$l[] | akey] | unique | length) != ($l | length) or ([$p[] | akey] | unique | length) != ($p | length)
  then w("a bypass actor appears more than once (no rule for comparing that)")
  else
    ( $l[] as $la | ($la | akey) as $k
      | ([$p[] | select(akey == $k)] | first) as $pa
      | if $pa == null then b("would remove live bypass actor \($k) (mode \($la.bypass_mode))")
        else each_difference("bypass actor \($k) "; $la; $pa;
          if .k == "bypass_mode" and (.l | type) == "string" then
            (.l | mode_rank) as $lr | (.p | mode_rank) as $pr
            | if $lr == null or $pr == null
                then w("would change bypass actor \($k) mode from \(.l) to \(.p) (no rule for this mode)")
              elif $pr > $lr then w("would widen bypass actor \($k) mode from \(.l) to \(.p)")
              else b("would narrow bypass actor \($k) mode from \(.l) to \(.p)") end
          else w("would change \(.path) (no rule for this field)") end)
        end ),
    ( $p[] | akey as $k
      | select(any($l[]; akey == $k) | not)
      | w("would add bypass actor \($k) in mode \(.bypass_mode)") )
  end;

$live[0] as $l | $preset[0] as $p
| each_difference(""; $l; $p;
    if .k == "enforcement" and (.l | type) == "string" then
      if (.l | enf_rank) != null and (.p | enf_rank) != null and (.p | enf_rank) > (.l | enf_rank)
      then t("raises enforcement from \(.l) to \(.p)")
      else w("would change enforcement from \(.l) to \(.p)") end
    elif .k == "conditions" and (.l | type) == "object" then conditions(.l; .p)
    elif .k == "rules" and (.l | type) == "array" then rules(.l; .p)
    elif .k == "bypass_actors" and (.l | type) == "array" then bypass(.l; .p)
    else w("would change \(.k) from \(.l | tojson) to \(.p | tojson)") end)
JQ_PROGRAM

# rc_classify <live-normalised-file> <preset-normalised-file>: sets CLASSIFIED,
# TIGHTENS, WEAKENS and REMOVES_BYPASS for two files known to differ.
rc_classify() {
  CLASSIFIED="$(jq -rn --slurpfile live "$1" --slurpfile preset "$2" "$RC_CLASSIFY_PROGRAM")"
  # Backstop: the files differ, so a classification that found nothing is a
  # difference this script could not name -- weakens, not fine.
  [[ -n "$CLASSIFIED" ]] || CLASSIFIED="$(printf 'weakens\ta difference this script could not classify')"
  TIGHTENS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "tightens" { print $2 }')"
  WEAKENS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "weakens" { print $2 }')"
  REMOVES_BYPASS="$(printf '%s\n' "$CLASSIFIED" | awk -F'\t' '$1 == "removes bypass" { print $2 }')"
}

# rc_print_kinds: the classified differences, one per line, with their kind.
rc_print_kinds() {
  local r
  [[ -z "$TIGHTENS" ]] || while IFS= read -r r; do echo "  tightens: $r"; done <<< "$TIGHTENS"
  [[ -z "$WEAKENS" ]] || while IFS= read -r r; do echo "  weakens: $r"; done <<< "$WEAKENS"
  [[ -z "$REMOVES_BYPASS" ]] || while IFS= read -r r; do echo "  removes bypass: $r (automation that relies on this bypass may be locked out)"; done <<< "$REMOVES_BYPASS"
}

# rc_print_flag_notes: which flag --apply would need, for a dry run.
rc_print_flag_notes() {
  [[ -z "$WEAKENS" ]] || echo "--apply would refuse this without --allow-weakening."
  [[ -z "$REMOVES_BYPASS" ]] || echo "--apply would refuse this without --allow-bypass-removal."
}

# rc_gate: for --apply. Prints a "refused:" line (stderr) for every
# difference its flag does not permit and sets BLOCKED to the flags that
# would. Returns 1 when something is blocked, 0 when --apply may write. Each
# flag permits only its own kind.
rc_gate() {
  local r
  BLOCKED=""
  if [[ -n "$WEAKENS" && "$ALLOW_WEAKENING" != "true" ]]; then
    while IFS= read -r r; do echo "refused: weakens: $r" >&2; done <<< "$WEAKENS"
    BLOCKED="$BLOCKED --allow-weakening"
  fi
  if [[ -n "$REMOVES_BYPASS" && "$ALLOW_BYPASS_REMOVAL" != "true" ]]; then
    while IFS= read -r r; do echo "refused: removes bypass: $r (automation that relies on this bypass may be locked out)" >&2; done <<< "$REMOVES_BYPASS"
    BLOCKED="$BLOCKED --allow-bypass-removal"
  fi
  [[ -z "$BLOCKED" ]]
}
