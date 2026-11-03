#!/bin/sh

# shellcheck disable=SC1091
. "$(dirname "$0")/shini.sh"

# shellcheck disable=SC2317
__shini_parse_error()
{
	case "$2" in
		"")
			;;
		"a")
			;;

		*)
			echo "Parse error thrown wrongly on '$1' '$2'" 1>&2
			FAIL=1
			;;
	esac
}

# shellcheck disable=SC2317
__shini_parsed_specific_test1()
{
        ERROR=0
        case "$1" in
                "test1sectionA")
                        case "$2" in
                                "test1c")
                                        ;;
                                "test1d")
                                        ;;
                                "test1e")
                                        ;;

                                *)
                                        ERROR=1
                                        ;;
                        esac
                        ;;

                *)
                        ERROR=1
                        ;;
        esac

        if [ "$3" != "b" ]; then
                FAIL=1
            fi

        if [ "$ERROR" -eq 1 ]; then
                echo "Parse provided wrong result on '$1' '$2' '$3'" 1>&2
                FAIL=1
        fi
}

# shellcheck disable=SC2317
__shini_parsed()
{
	ERROR=0
	case "$1" in
		"")
			case "$2" in
				"test1a")
					;;
				"test1b")
					;;

				*)
					ERROR=1
					;;
			esac
			;;
		"test1sectionA")
			case "$2" in
				"test1c")
					;;
				"test1d")
					;;
				"test1e")
					;;

				*)
					ERROR=1
					;;
			esac
			;;

		*)
			ERROR=1
			;;
	esac

	if [ "$3" != "b" ]; then
		echo "Parse returned wrong value during basic test '$3' instead of 'b'" 1>&2
		FAIL=1
	fi

	if [ "$ERROR" -eq 1 ]; then
		echo "Parse provided wrong result on '$1' '$2' '$3'" 1>&2
		FAIL=1
	fi
}

# shellcheck disable=SC2317
__shini_file_unreadable()
{
	case "$1" in
		"tests/nonexistent.ini")
			;;

		*)
			echo "File unreadable failed on '$1'" 1>&2
			FAIL=1
			;;
	esac
}

FAIL=0

shini_parse "tests/nonexistent.ini" || true
shini_parse "tests/test1.ini"
shini_parse "tests/test2.ini"

## Write tests

FAIL=0

TEMP="$(mktemp -t shini_test_XXXXXX)"
printf "
[SECTION1]
abc=\"123\"
[SECTION2]
def=\"456\" ; comment
quack=duck ; comment
ccc=ccc" > "$TEMP"

shini_write "$TEMP" "SECTION1" "qqq" "aaa" 
shini_write "$TEMP" "SECTION1" "qqq" "abc"
shini_write "$TEMP" "SECTION1" "qqq" "ddd"
shini_write "$TEMP" "SECTION2" "rrr" "sss"
shini_write "$TEMP" "SECTION1" "abc" "bbb" 
shini_write "$TEMP" "SECTION3" "xxx" "yyy"

if ! grep -q '^qqq=ddd$' "$TEMP"; then
    echo "Writing failed (qqq=ddd)"
    FAIL=1
fi

if grep -q '^abc=123$' "$TEMP"; then
    echo "Updating failed (abc=123 still remains)"
    FAIL=1
fi

if ! grep -q '^quack=duck *; comment$' "$TEMP"; then
    echo "Write corruption (quack=duck)"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
	echo "************ Resulting INI (1) ************"
	cat "$TEMP"
	echo "************        EOF        ************"
fi

# Quoted write tests

shini_write "$TEMP" "SECTION3" "rrr" " s s s " true
shini_write "$TEMP" "SECTION1" "qqq" "ddd" true

if ! grep -q '^rrr=" s s s "$' "$TEMP"; then
    echo "Quoted writing failed (rrr=\" s s s \")"
    FAIL=1
fi

if ! grep -q '^qqq="ddd"$' "$TEMP"; then
    echo "Quoted updating failed (qqq=\"ddd\")"
    FAIL=1
fi

# Lines other than the one being written must be left exactly as they were (issue #13)
if ! grep -q '^quack=duck *; comment$' "$TEMP"; then
    echo "Quoted write corruption (quack=duck was changed)"
    FAIL=1
fi

if ! grep -q '^def="456" *; comment$' "$TEMP"; then
    echo "Write corruption (quoted def=\"456\" lost its quotes)"
    FAIL=1
fi

if ! grep -q '^ccc=ccc$' "$TEMP"; then
    echo "Quoted write corruption (unquoted ccc=ccc was changed)"
    FAIL=1
fi

if grep -q '^abc="123"$' "$TEMP"; then
    echo "Quoted write corruption (abc=\"123\" is broken)"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
	echo "************ Resulting INI (2) ************"
	cat "$TEMP"
	echo "************        EOF        ************"
fi

## Writing must not alter other lines: quotes, indentation, spacing, comments (issue #13)

TEMP13="$(mktemp -t shini_test13_XXXXXX)"
printf '[Sec]\nquoted="string value"\nplain=abc\n  indented = "x"  ; cm ; two\n  ; indented comment\n[Other]\nk=v' > "$TEMP13"

shini_write "$TEMP13" "Sec" "added" "1"
shini_write "$TEMP13" "Sec" "added2" "two words" true
shini_write "$TEMP13" "Other" "k" "new"

for EXPECTED in 'quoted="string value"' 'plain=abc' '  indented = "x"  ; cm ; two' '  ; indented comment' 'added=1' 'added2="two words"' 'k=new'; do
    if ! grep -qxF -- "$EXPECTED" "$TEMP13"; then
        echo "Write changed or lost a line (issue #13): '$EXPECTED'"
        FAIL=1
    fi
done

# Updating a key keeps its comment; deleting a key removes its comment with it
printf '[S]\na=1 ; keep me\nb=2 ; drop me\nc=3\n' > "$TEMP13"
shini_write "$TEMP13" "S" "a" "9"
shini_write "$TEMP13" "S" "b" ""
if ! grep -qx 'a=9 ; keep me' "$TEMP13" || grep -q 'drop me' "$TEMP13" || ! grep -qx 'c=3' "$TEMP13"; then
    echo "Update/delete handled comments wrongly"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "************ Resulting INI (3) ************"
    cat "$TEMP13"
    echo "************        EOF        ************"
fi
rm -f "$TEMP13"

## A quoted value without a closing quote is read to the end of the line

# shellcheck disable=SC2317
__shini_parsed_unterminated()
{
    UNTERMINATED="$3"
}

TEMPU="$(mktemp -t shini_testu_XXXXXX)"
printf '[S]\nk="abc ; def\n' > "$TEMPU"
UNTERMINATED=''
shini_parse "$TEMPU" "unterminated"
if [ "$UNTERMINATED" != 'abc ; def' ]; then
    echo "Unterminated quoted value read wrongly: '$UNTERMINATED' instead of 'abc ; def'"
    FAIL=1
fi
rm -f "$TEMPU"

## Specific section test

shini_parse_section "tests/test1.ini" "test1sectionA" "specific_test1"

## Specific key test

VALUE="$(shini_read tests/test2.ini "" test1b)"
if [ "$VALUE" != "b" ]; then
	echo "Read of specific key failed: '$VALUE' instead of 'b'" 1>&2
fi

rm -f "$TEMP"

exit $FAIL
