#!/bin/sh
# shini - compatible INI library for sh
#
# This code is released freely under the MIT license - see the shipped LICENSE document.
# For the latest version etc, please see https://github.com/wallyhall/shini
#

# Solely for the purpose of portable performance, this script breaks good practice to
# avoid forking subshells.  One such good practice is avoiding global variables.
# This variable is used to carry non-numeric results from functions to the caller.
# Alternatively an echo and "$(...)" approach could be used, but is significantly slower.
#
# Parsing is done with POSIX `case` patterns and parameter expansion only - no regex,
# no grep/sed and no subshell per line.  That makes it fast on busybox ash (where every
# fork+exec is expensive) and identical in behaviour on bash, ksh, zsh, dash and ash.

shini_function_exists()
{
    type "$1" > /dev/null 2>&1
    return $?
}

# @param inifile Filename of INI file to parse
# @param postfix Function postfix for callbacks (optional)
# @param extra Extra argument for callbacks (optional)
shini_parse()
{
    shini_parse_section "$1" '' "$2" "$3" "$4" "$5"
    return $?
}

# @param inifile Filename of INI file to parse
# @param section Section to parse (or empty string for entire file)
# @param postfix Function postfix for callbacks (optional)
# @param extra Extra argument for callbacks (optional)
shini_parse_section()
{
    SKIP_TO_SECTION="${2:-}"
    POSTFIX="${3:+_$3}"
    EXTRA1="${4:-}"
    EXTRA2="${5:-}"
    EXTRA3="${6:-}"
    SECTION_FOUND=-1

    # Callback names are resolved once, not once per line.
    CB_PARSED="__shini_parsed${POSTFIX}"
    CB_SECTION="__shini_parsed_section${POSTFIX}"
    CB_COMMENT="__shini_parsed_comment${POSTFIX}"
    CB_COMMENT_LINE="__shini_parsed_comment_line${POSTFIX}"
    CB_ERROR="__shini_parse_error${POSTFIX}"

    if ! shini_function_exists "$CB_PARSED"; then
        printf 'shini: __shini_parsed%s function not declared.\n' "${POSTFIX}" 1>&2
        return 255
    fi

    if [ $# -lt 1 ]; then
        if shini_function_exists "__shini_no_file_passed${POSTFIX}"; then
            "__shini_no_file_passed${POSTFIX}" "$EXTRA1" "$EXTRA2" "$EXTRA3"
            return 254
        else
            printf 'shini: Argument 1 needs to specify the INI file to parse.\n' 1>&2
            return 254
        fi
    fi
    INI_FILE="$1"

    if [ ! -r "$INI_FILE" ]; then
        if shini_function_exists "__shini_file_unreadable${POSTFIX}"; then
            "__shini_file_unreadable${POSTFIX}" "$INI_FILE" "$EXTRA1" "$EXTRA2" "$EXTRA3"
            return 253
        else
            # shellcheck disable=SC2016
            printf 'shini: Unable to read INI file:\n  `%s`\n' "$INI_FILE" 1>&2
            return 253
        fi
    fi

    # Which optional callbacks exist (empty = no).  Checked once, not once per line.
    HAS_CB_SECTION=''
    HAS_CB_COMMENT=''
    HAS_CB_COMMENT_LINE=''
    HAS_CB_ERROR=''
    shini_function_exists "$CB_SECTION"      && HAS_CB_SECTION=1
    shini_function_exists "$CB_COMMENT"      && HAS_CB_COMMENT=1
    shini_function_exists "$CB_COMMENT_LINE" && HAS_CB_COMMENT_LINE=1
    shini_function_exists "$CB_ERROR"        && HAS_CB_ERROR=1

    # Iterate INI file line by line
    LINE_NUM=-1
    SECTION=''
    while read -r LINE || [ -n "$LINE" ]; do  # -n $LINE catches final line if not empty
        LINE_NUM=$((LINE_NUM+1))

        # `read` already strips leading/trailing blanks with the default IFS; this keeps
        # parsing tolerant if the caller changed IFS.  It costs two cheap pattern matches.
        case "$LINE" in
            [[:blank:]]*) LINE="${LINE#"${LINE%%[![:blank:]]*}"}" ;;
        esac
        case "$LINE" in
            *[[:blank:]]) LINE="${LINE%"${LINE##*[![:blank:]]}"}" ;;
        esac

        [ -z "$LINE" ] && continue

        # Check for new sections:  [name]  where name is [a-zA-Z0-9_-]+
        case "$LINE" in
            \[*\])
                TMP="${LINE#\[}"
                TMP="${TMP%\]}"
                case "$TMP" in
                    ''|*[!a-zA-Z0-9_-]*)
                        ;;  # not a valid section name - fall through to the other checks
                    *)
                        SECTION="$TMP"

                        if [ -n "$SKIP_TO_SECTION" ]; then
                            # stop once specific section is finished
                            [ "$SECTION_FOUND" -eq 0 ] && break

                            # mark the specified section as found
                            [ "$SKIP_TO_SECTION" = "$SECTION" ] && SECTION_FOUND=0
                        fi

                        if [ -n "$HAS_CB_SECTION" ]; then
                            "$CB_SECTION" "$SECTION" "$EXTRA1" "$EXTRA2" "$EXTRA3" || break
                        fi

                        continue
                        ;;
                esac
                ;;
        esac

        # Skip over sections we don't care about, if a specific section was specified
        if [ -n "$SKIP_TO_SECTION" ] && [ "$SECTION_FOUND" -ne 0 ]; then
            continue
        fi

        # Check for comment lines
        case "$LINE" in
            \;*)
                if [ -n "$HAS_CB_COMMENT_LINE" ]; then
                    COMMENT="${LINE#;}" # strip the leading comment marker
                    "$CB_COMMENT_LINE" "$COMMENT" "$EXTRA1" "$EXTRA2" "$EXTRA3" || break
                fi
                continue
                ;;
        esac

        # Check for key/value lines:  key = value [; comment]
        #   key    [a-zA-Z0-9_.-]+
        #   value  "quoted"  or  unquoted (no double quotes, ends at first ';')
        KV=''
        case "$LINE" in
            *=*)
                KEY="${LINE%%=*}"
                KEY="${KEY%"${KEY##*[![:space:]]}"}" # trim trailing whitespace
                case "$KEY" in
                    ''|*[!a-zA-Z0-9_.-]*)
                        ;;  # not a valid key
                    *)
                        VALCOM="${LINE#*=}" # everything after the first '='
                        VALCOM="${VALCOM#"${VALCOM%%[![:space:]]*}"}" # trim leading whitespace
                        HAS_COMMENT=''
                        COMMENT=''
                        case "$VALCOM" in
                            \"*)
                                TMP="${VALCOM#\"}"
                                case "$TMP" in
                                    *\"*)
                                        VALUE="${TMP%%\"*}" # up to the closing quote
                                        TMP="${TMP#*\"}"    # what follows the closing quote
                                        TMP="${TMP#"${TMP%%[![:blank:]]*}"}"
                                        case "$TMP" in
                                            '')
                                                KV=1
                                                ;;
                                            \;*)
                                                COMMENT="${TMP#;}"
                                                HAS_COMMENT=1
                                                KV=1
                                                ;;
                                        esac
                                        ;;
                                esac
                                ;;
                            *)
                                TMP="${VALCOM%%\;*}" # strip from the first comment marker
                                case "$TMP" in
                                    *\"*)
                                        ;;  # stray double quote in an unquoted value
                                    *)
                                        VALUE="${TMP%"${TMP##*[![:space:]]}"}" # trim trailing whitespace
                                        if [ "$TMP" != "$VALCOM" ]; then
                                            COMMENT="${VALCOM#*\;}"
                                            HAS_COMMENT=1
                                        fi
                                        KV=1
                                        ;;
                                esac
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac

        if [ -n "$KV" ]; then
            "$CB_PARSED" "$SECTION" "$KEY" "$VALUE" "$EXTRA1" "$EXTRA2" "$EXTRA3" || break

            if [ -n "$HAS_COMMENT" ] && [ -n "$HAS_CB_COMMENT" ]; then
                "$CB_COMMENT" "$COMMENT" "$EXTRA1" "$EXTRA2" "$EXTRA3" || break
            fi

            continue
        fi

        # Announce parse errors (blank and comment lines were handled above)
        if [ -n "$HAS_CB_ERROR" ]; then
            "$CB_ERROR" "$LINE_NUM" "$LINE" "$EXTRA1" "$EXTRA2" "$EXTRA3" || break
        else
            # shellcheck disable=SC2016
            printf 'shini: Unable to parse line %d:\n  `%s`\n' "$LINE_NUM" "$LINE" 1>&2
        fi
    done < "$INI_FILE"

    return 0
}

# SUBSHELL FUNCTION
# @param inifile Filename of INI file to write to
# @param section Section of INI file to write to
# @param variable Variable name to add/update/delete
# @param value Value to add/update, do not specify to delete
# @param quote (Double-)quote the value being written (default: false)
shini_write()
(
    # This is not yet optimised (early write support only) -
    # We actually re-parse the entire file, looking for the location in which to
    # write the new value, writing out everything we parse as-is meanwhile.

    # Declare the following if you want particular behaviour (like skipping
    # broken INI file content or handling an unreadable file etc).
    #  __shini_no_file_passed__writer()
    #  __shini_file_unreadable__writer()
    #  __shini_parse_error__writer()

    # Writer callbacks, used for writing the INI file content
    # shellcheck disable=SC2317
    __shini_parsed_section__writer()
    {
        # Validate the last section wasn't the target section
        if [ "$LAST_SECTION" = "$WRITE_SECTION" ]; then
            # If it was, and the value wasn't written already, write it
            if [ "$VALUE_WRITTEN" -eq 0 ]; then
                # shellcheck disable=SC2059
                printf "$PRINTFMT" "$WRITE_KEY" "$WRITE_VALUE" >&3
                VALUE_WRITTEN=1
            fi
        fi

        printf "\n[%s]" "$1" >&3

        LAST_SECTION="$1"
    }

    # shellcheck disable=SC2317
    __shini_parsed_comment__writer()
    {
        printf " ;%s" "$1" >&3
    }

    # shellcheck disable=SC2317
    __shini_parsed_comment_line__writer()
    {
        printf "\n;%s" "$1" >&3
    }

    # shellcheck disable=SC2317
    __shini_parsed__writer()
    {
        if [ "$1" = "$WRITE_SECTION" ]; then
            if [ "$2" = "$WRITE_KEY" ]; then
                if [ -n "$WRITE_VALUE" ]; then
                    # shellcheck disable=SC2059
                    printf "$PRINTFMT" "$WRITE_KEY" "$WRITE_VALUE" >&3
                fi
                VALUE_WRITTEN=1
                return
            fi
        fi

        # shellcheck disable=SC2059
        printf "$PRINTFMT" "$2" "$3" >&3
    }

    if [ $# -lt 3 ]; then
        if shini_function_exists "__shini_no_file_passed"; then
            __shini_no_file_passed
        else
            printf 'shini: Argument 1 needs to specify the INI file to write.\n' 1>&2
            return 254
        fi
    fi

    INI_FILE="$1"
    INI_FILE_TEMP="$(mktemp -t shini_XXXXXX)"

    WRITE_SECTION="$2"
    WRITE_KEY="$3"
    WRITE_VALUE="$4"
    LAST_SECTION=""
    VALUE_WRITTEN=0

    # "Quote value" mode (true/false)
    if [ -n "$5" ] && [ "$5" = true ]; then
        PRINTFMT='\n%s="%s"'
    else
        PRINTFMT='\n%s=%s'
    fi

    # Keep the temp file open on fd 3 instead of re-opening it for every line written.
    exec 3>> "$INI_FILE_TEMP"

    shini_parse "$INI_FILE" "_writer" "$WRITE_SECTION" "$WRITE_KEY" "$WRITE_VALUE"
    # Still not written out yet
    if [ "$VALUE_WRITTEN" -eq 0 ]; then
        # Check if final existing section was target one, add it if not
        if [ "$LAST_SECTION" != "$WRITE_SECTION" ]; then
            printf "\n[%s]" "$WRITE_SECTION" >&3
        fi
        # Write value at end of file
        # shellcheck disable=SC2059
        printf "$PRINTFMT" "$WRITE_KEY" "$WRITE_VALUE" >&3
    fi

    exec 3>&-

    tail -n +2 "$INI_FILE_TEMP" > "$INI_FILE"
    rm -f "$INI_FILE_TEMP"

    return 0
)

# SUBSHELL FUNCTION
# @param inifile Filename of INI file to read from
# @param section Section of INI file to read from (blank string if sectionless INI)
# @param key to read
shini_read()
(
    # shellcheck disable=SC2317
    __shini_parsed__key_read()
    {
        if [ "$1" = "$READ_SECTION" ]; then
            if [ "$2" = "$READ_KEY" ]; then
                printf "%s" "$3"
                FOUND=1
                return 1  # exit condition for shini_parse
            fi
        fi
    }

    INI_FILE="$1"

    READ_SECTION="$2"
    READ_KEY="$3"

    FOUND=0

    shini_parse "$INI_FILE" "_key_read" "$READ_SECTION" "$READ_KEY"

    if [ $FOUND -eq 0 ]; then
        return 1
    else
        return 0
    fi
)
