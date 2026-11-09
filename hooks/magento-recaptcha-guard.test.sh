#!/bin/bash
# Test suite for magento-recaptcha-guard.sh — feed PreToolUse JSON, assert exit.
# Run: bash magento-recaptcha-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/magento-recaptcha-guard.sh"
PASS=0; FAIL=0

check() {
  local expect="$1" desc="$2" json="$3" got
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect got $got"; fi
}

b() { check "$1" "$2" "$(jq -n --arg c "$3" '{tool_name:"Bash", tool_input:{command:$c}}')"; }
edit() { check "$1" "$2" "$(jq -n --arg f "$3" --arg o "$4" --arg n "$5" '{tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}}')"; }
write() { check "$1" "$2" "$(jq -n --arg f "$3" --arg c "$4" '{tool_name:"Write", tool_input:{file_path:$f, content:$c}}')"; }
mcp() { check "$1" "$2" "$(jq -n --arg q "$3" '{tool_name:"mcp__database__execute_query", tool_input:{query:$q}}')"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
git -c init.defaultBranch=main init -q "$TMP" 2>/dev/null
mkdir -p "$TMP/app/etc" "$TMP/app/code/V/M/Setup/Patch/Data" "$TMP/app/code/V/M/Test/Unit"

ENV="$TMP/app/etc/env.dev.php"
cat > "$ENV" <<'PHP'
<?php
return [
    'system' => [
        'default' => [
            'recaptcha_frontend' => [
                'type_for' => [
                    'customer_login' => 'recaptcha_v3',
                    'customer_create' => 'recaptcha_v3'
                ],
                'type_recaptcha_v3' => [
                    'score_threshold' => '0'
                ]
            ],
            'web' => [ 'unsecure' => [ 'base_url' => 'https://x/' ] ]
        ]
    ]
];
PHP

# --- Edit: env files --------------------------------------------------------
edit 2 "set form to null"      "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => null"
edit 2 "set form to empty"     "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => ''"
edit 2 "set form to 0"         "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => 0"
edit 2 "set form to '0'"       "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => '0'"
edit 2 "remove a form"         "$ENV" "'customer_login' => 'recaptcha_v3',
" ""
edit 2 "empty type_for"        "$ENV" "'customer_login' => 'recaptcha_v3',
                    'customer_create' => 'recaptcha_v3'" ""
edit 0 "unrelated edit"        "$ENV" "https://x/" "https://y/"
edit 0 "change type stays on"  "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => 'invisible'"
edit 0 "keys and threshold"    "$ENV" "'score_threshold' => '0'" "'score_threshold' => '0.5'"
edit 0 "add test token" "$ENV" "'type_recaptcha_v3' => [" "'test_mode' => [ 'token' => 'abc' ],
                'type_recaptcha_v3' => ["

# --- Write: whole-file ------------------------------------------------------
ONE_LINE="<?php return ['system'=>['default'=>['recaptcha_frontend'=>['type_for'=>['customer_login'=>null]]]]];"
write 2 "new env file, one-line null" "$TMP/app/etc/env.new.php" "$ONE_LINE"
write 2 "array() syntax null" "$TMP/app/etc/env.old.php" "<?php return array('system'=>array('default'=>array('recaptcha_backend'=>array('type_for'=>array('user_login'=>null)))));"
write 2 "overwrite drops recaptcha" "$ENV" "<?php return ['system'=>['default'=>[]]];"
write 2 "module disabled" "$TMP/app/etc/config.php" "<?php return ['modules'=>['Magento_ReCaptchaUser'=>0]];"
write 0 "module enabled" "$TMP/app/etc/config.php" "<?php return ['modules'=>['Magento_ReCaptchaUser'=>1,'Magento_TwoFactorAuth'=>0]];"
write 0 "non-recaptcha env" "$TMP/app/etc/env.other.php" "<?php return ['db'=>['x'=>null]];"
write 0 "comment mentioning null" "$TMP/app/etc/env.c.php" "<?php return [ // 'recaptcha_frontend'=>['type_for'=>['a'=>null]]
'x'=>1];"

# --- already-wrong file: unrelated edits pass, new disables block -----------
BAD="$TMP/app/etc/env.uat.php"
cat > "$BAD" <<'PHP'
<?php
return ['system' => ['default' => ['recaptcha_backend' => ['type_for' => [
    'user_login' => null,
    'user_forgot_password' => 'recaptcha_v3'
]], 'web' => ['a' => 'b']]]];
PHP
edit 0 "unrelated edit, existing null" "$BAD" "'a' => 'b'" "'a' => 'c'"
edit 0 "fixing the null passes"        "$BAD" "'user_login' => null" "'user_login' => 'recaptcha_v3'"
edit 2 "second null on wrong file"     "$BAD" "'user_forgot_password' => 'recaptcha_v3'" "'user_forgot_password' => null"

# --- data patches -----------------------------------------------------------
P="$TMP/app/code/V/M/Setup/Patch/Data/Off.php"
write 2 "patch deleteConfig" "$P" "<?php \$w->deleteConfig('recaptcha_frontend/type_for/customer_login');"
write 2 "patch save null" "$P" "<?php \$w->save('recaptcha_frontend/type_for/customer_login', null, 'default', 0);"
write 2 "patch save empty multiline" "$P" "<?php \$w->save(
  'recaptcha_backend/type_for/user_login',
  '',
  'default');"
write 0 "patch sets v3" "$P" "<?php \$w->save('recaptcha_frontend/type_for/customer_login', 'recaptcha_v3');"
write 0 "unrelated patch" "$P" "<?php \$w->save('web/x/y', null);"
write 0 "under Test dir" "$TMP/app/code/V/M/Setup/Test/Unit/X.php" "<?php \$w->deleteConfig('recaptcha_frontend/type_for/a');"
write 0 "not Setup" "$TMP/app/code/V/M/Model/X.php" "<?php \$w->deleteConfig('recaptcha_frontend/type_for/a');"

# --- Bash: magento commands -------------------------------------------------
b 2 "config:set empty"      "bin/magento config:set recaptcha_frontend/type_for/customer_login ''"
b 2 "config:set null"       "php bin/magento config:set recaptcha_frontend/type_for/customer_login null"
b 2 "config:set 0"          "bin/magento config:set recaptcha_backend/type_for/user_login 0"
b 2 "config:set no value"   "bin/magento config:set recaptcha_frontend/type_for/contact"
b 2 "config:set with scope" "bin/magento config:set --scope=default recaptcha_frontend/type_for/contact ''"
b 2 "after &&"              "cd /x && bin/magento config:set recaptcha_frontend/type_for/contact ''"
b 2 "ddev exec"             "ddev exec bin/magento config:set recaptcha_frontend/type_for/contact ''"
b 2 "ddev magento"          "ddev magento config:set recaptcha_frontend/type_for/contact ''"
b 2 "n98 store set"         "n98-magerun2 config:store:set recaptcha_frontend/type_for/contact ''"
b 2 "config:delete"         "bin/magento config:delete recaptcha_frontend/type_for/contact"
b 2 "n98 store delete"      "n98-magerun2 config:store:delete recaptcha_backend/type_for/user_login"
b 2 "core disable login"    "bin/magento security:recaptcha:disable-for-user-login"
b 2 "core disable forgot"   "bin/magento security:recaptcha:disable-for-user-forgot-password"
b 2 "module:disable"        "bin/magento module:disable Magento_ReCaptchaCustomer"
b 0 "config:set v3"         "bin/magento config:set recaptcha_frontend/type_for/contact recaptcha_v3"
b 0 "config:set v3 quoted"  "bin/magento config:set recaptcha_frontend/type_for/contact 'recaptcha_v3' --lock-env"
b 0 "config:set key"        "bin/magento config:set recaptcha_frontend/type_recaptcha_v3/public_key abc"
b 0 "config:set unrelated"  "bin/magento config:set web/x/y ''"
b 0 "config:show"           "bin/magento config:show recaptcha_frontend/type_for"
b 0 "module:disable other"  "bin/magento module:disable Magento_TwoFactorAuth"
b 0 "grep words"            "grep -rn 'config:delete recaptcha_frontend' docs/"
b 0 "echo words"            "echo bin/magento security:recaptcha:disable-for-user-login"

# --- Bash: SQL --------------------------------------------------------------
b 2 "mysql delete"   "mysql db -e \"DELETE FROM core_config_data WHERE path LIKE 'recaptcha_frontend/%'\""
b 2 "mysql blank"    "mysql db -e \"UPDATE core_config_data SET value = NULL WHERE path = 'recaptcha_frontend/type_for/contact'\""
b 2 "mysql empty"    "mysql db -e \"UPDATE core_config_data SET value='' WHERE path LIKE 'recaptcha_backend%'\""
b 2 "mysql insert"   "mysql db -e \"INSERT INTO core_config_data (path,value) VALUES ('recaptcha_frontend/type_for/contact', NULL)\""
b 0 "mysql select"   "mysql db -e \"SELECT * FROM core_config_data WHERE path LIKE 'recaptcha_frontend/%'\""
b 0 "mysql set v3"   "mysql db -e \"UPDATE core_config_data SET value='recaptcha_v3' WHERE path='recaptcha_frontend/type_for/contact'\""
b 0 "mysql other"    "mysql db -e \"DELETE FROM core_config_data WHERE path LIKE 'web/%'\""
b 0 "grep SQL words" "grep -rn \"DELETE FROM core_config_data recaptcha_frontend\" docs/"
mcp 2 "mcp delete"   "DELETE FROM core_config_data WHERE path LIKE 'recaptcha_frontend/%'"
mcp 2 "mcp blank"    "UPDATE core_config_data SET value=NULL WHERE path='recaptcha_backend/type_for/user_login'"
mcp 0 "mcp select"   "SELECT value FROM core_config_data WHERE path LIKE 'recaptcha_%'"
mcp 0 "mcp other"    "DELETE FROM quote WHERE 1"

# --- Bash: direct env writes ------------------------------------------------
b 2 "sed -i env"     "sed -i \"s/'customer_login' => 'recaptcha_v3'/'customer_login' => null/; s/type_for/x/\" app/etc/env.dev.php"
b 2 "php file_put"   "php -r '\$c=include \"app/etc/env.dev.php\"; unset(\$c[\"system\"][\"default\"][\"recaptcha_frontend\"]); file_put_contents(\"app/etc/env.dev.php\", \$c);'"
b 0 "sed -i env other" "sed -i 's/foo/bar/' app/etc/env.dev.php"
b 0 "cp env files"   "cp app/etc/env.dev.php app/etc/env.php"
b 0 "grep to tmp"    "grep recaptcha_frontend app/etc/env.php > /tmp/x"
b 0 "php -r read"    "php -r '\$c=include \"app/etc/env.php\"; print_r(\$c[\"system\"][\"default\"][\"recaptcha_frontend\"]);'"

# --- opt-out + escape -------------------------------------------------------
mkdir -p "$TMP/.claude"
printf 'magento-recaptcha-guard\n' > "$TMP/.claude/rules-disable"
edit 0 "opt-out disarms" "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => null"
printf 'other-guard\n' > "$TMP/.claude/rules-disable"
edit 2 "unrelated opt-out" "$ENV" "'customer_login' => 'recaptcha_v3'" "'customer_login' => null"

jq -n '{tool_name:"Bash", tool_input:{command:"bin/magento config:delete recaptcha_frontend/type_for/a"}}' \
  | CLAUDE_RECAPTCHA_DISABLE_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: env escape should allow"; }

# --- fails soft -------------------------------------------------------------
echo '' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: empty input should no-op"; }
echo 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: garbage input should no-op"; }

echo "magento-recaptcha-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
