# Plowshare Rockfile.eu module
# Copyright (c) 2016 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_ROCKFILE_EU_REGEXP_URL='https\?://\(www\.\)\?rockfile\.eu/'

MODULE_ROCKFILE_EU_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_ROCKFILE_EU_UPLOAD_REMOTE_SUPPORT=no

# Static function. Check for and handle "DDoS protection"
# $1: full content of initial page
# $2: cookie file
# $3: url (base url or file url)
rockfile_eu_cloudflare() {
    local PAGE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL="$(basename_url "$3")"

    # check for DDoS protection
    # <title>Just a moment...</title>
    if [[ $(parse_tag 'title' <<< "$PAGE") = *Just\ a\ moment* ]]; then
        local TRY FORM_HTML FORM_VC FORM_PASS FORM_ANSWER JS

        detect_javascript || return

        # Note: We may not pass DDoS protection for the first time.
        #       Limit loop to max 5.
        TRY=0
        while (( TRY++ < 5 )); do
            log_debug "CloudFlare DDoS protection found - try $TRY"

            wait 5 || return

            FORM_HTML=$(grep_form_by_id "$PAGE" 'challenge-form') || return
            FORM_VC=$(parse_form_input_by_name 'jschl_vc' <<< "$FORM_HTML") || return
            FORM_PASS=$(parse_form_input_by_name 'pass' <<< "$FORM_HTML") || return

            # Obfuscated javascript code
            JS=$(grep_script_by_order "$PAGE") || return
            JS=${JS#*<script type=\"text/javascript\">}
            JS=${JS%*</script>}

            FORM_ANSWER=$(echo "
                function a_obj() {
                    this.style = new Object();
                    this.style.display = new Object();
                };
                function form_obj() {
                    this.submit = function () {
                        return;
                    }
                };
                function href_obj() {
                    this.firstChild = new Object();
                    this.firstChild.href = '$BASE_URL/';
                };
                var elts = new Array();
                var document = {
                    attachEvent: function(name,value) {
                        return value();
                    },
                    createElement: function(id) {
                        return new href_obj();
                    },
                    getElementById: function(id) {
                        if (! elts[id] && id == 'cf-content') {
                            elts[id] = new a_obj();
                        }
                        if (! elts[id] && id == 'challenge-form') {
                            elts[id] = new form_obj();
                        }
                        if (! elts[id]) {
                            elts[id] = {};
                        }
                        return elts[id];
                    }
                };
                var final_fun;
                function setTimeout(value,time) {
                    final_fun = value;
                };
                $JS
                final_fun();
                if (typeof console === 'object' && typeof console.log === 'function') {
                    console.log(elts['jschl-answer'].value);
                } else {
                    print(elts['jschl-answer'].value);
                }" | javascript) || return

                # Set-Cookie: cf_clearance
                PAGE=$(curl -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                    "$BASE_URL/cdn-cgi/l/chk_jschl?jschl_vc=$FORM_VC&pass=$FORM_PASS&jschl_answer=$FORM_ANSWER") || return

                if [[ $(parse_tag 'title' <<< "$PAGE") != *Just\ a\ moment* ]]; then
                    break
                fi
            done
        fi
}

# Switch language to english
# $1: cookie file
# $2: base URL
rockfile_eu_switch_lang() {
    # Set-Cookie: lang
    curl "$2" -b "$1" -c "$1" -d 'op=change_lang' \
        -d 'lang=english' > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
rockfile_eu_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA STATUS NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
        if ! match '>Used space:<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL") || return
        rockfile_eu_cloudflare "$PAGE" "$COOKIE_FILE" "$BASE_URL" || return
        rockfile_eu_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

        LOGIN_DATA='op=login&redirect=account&login=$USER&password=$PASSWORD'

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL" -L -b "$COOKIE_FILE") || return

        # If successful Set-Cookie: login xfss
        STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
        [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")

    if match 'Go premium<' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Upload a file to rockfile.eu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
rockfile_eu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://rockfile.eu'

    local ACCOUNT PAGE USER_TYPE UPLOAD_ID TAGS_STR
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_SRV_TMP FORM_BUTTON
    local FORM_FN FORM_ST FORM_OP

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(rockfile_eu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/upload_files") || return
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$PAGE") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")
    FORM_SRV_TMP=$(parse_form_input_by_name 'srv_tmp_url' <<< "$PAGE") || return
    FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$PAGE") || return

    # "reg"
    USER_TYPE=$(parse 'var utype' "='\([^']*\)" <<< "$PAGE") || return
    log_debug "User type: '$USER_TYPE'"

    UPLOAD_ID=$(random dec 12) || return
    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "file_0_descr=$DESCRIPTION" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        --form-string 'to_folder=' \
        --form-string "submit_btn=$FORM_BUTTON" \
        "${FORM_ACTION}${UPLOAD_ID}&utype=${USER_TYPE}&js_on=1&upload_type=${FORM_UTYPE}" | break_html_lines) || return

    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_FN=$(parse_tag "name='fn'" textarea <<< "$PAGE") || return
    FORM_ST=$(parse_tag "name='st'" textarea <<< "$PAGE") || return
    FORM_OP=$(parse_tag "name='op'" textarea <<< "$PAGE") || return

    if [ "$FORM_ST" = 'OK' ]; then
        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "fn=$FORM_FN" \
            -d "st=$FORM_ST" \
            -d "op=$FORM_OP" \
            "$FORM_ACTION") || return

        parse '>Download Link<' '">\(.*\)$' 1 <<< "$PAGE" || return
        parse '>Delete Link<' '">\(.*\)$' 1 <<< "$PAGE" || return
        return 0
    fi

    log_error "Unexpected status: $FORM_ST"
    return $ERR_FATAL
}
