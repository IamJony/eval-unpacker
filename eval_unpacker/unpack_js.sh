#!/usr/bin/env bash
# unpack_js.sh — Unpacker de eval(function(p,a,c,k,e,d){...}) en bash
# Uso: ./unpack_js.sh archivo.js   |   cat archivo.js | ./unpack_js.sh -

set -euo pipefail

DIGITS="0123456789abcdefghijklmnopqrstuvwxyz"
SEP=$'\x1f'   # unit separator: no aparece en JS normal

# ---------- utilidades ----------
num_to_base() {
    local n=$1 base=$2
    (( n == 0 )) && { printf '0'; return; }
    (( base < 2 || base > 36 )) && { echo "base must be 2..36" >&2; return 1; }
    local out=""
    while (( n > 0 )); do
        local d=$(( n % base ))
        out="${DIGITS:$d:1}$out"
        n=$(( n / base ))
    done
    printf '%s' "$out"
}

unescape_js_string() {
    local s=$1
    s=${s//\\\\/__BS__}
    s=${s//\\\'/\'}
    s=${s//\\\"/\"}
    s=${s//__BS__/\\}

    while [[ $s =~ \\x([0-9a-fA-F]{2}) ]]; do
        local hex="${BASH_REMATCH[1]}"
        local dec=$((16#$hex))
        local ch
        ch=$(printf "\\$(printf '%03o' "$dec")")
        s="${s//\\x$hex/$ch}"
    done

    while [[ $s =~ \\u([0-9a-fA-F]{4}) ]]; do
        local hex="${BASH_REMATCH[1]}"
        local dec=$((16#$hex))
        local ch
        if (( dec < 128 )); then
            ch=$(printf "\\$(printf '%03o' "$dec")")
        else
            ch=$(printf '%b' "\\u$hex")
        fi
        s="${s//\\u$hex/$ch}"
    done

    s=${s//\\n/$'\n'}
    s=${s//\\r/$'\r'}
    s=${s//\\t/$'\t'}
    printf '%s' "$s"
}

# ---------- parseo de args top-level ----------
# Imprime args separados por $SEP (no por \n) para sobrevivir a saltos de línea internos
parse_top_level_args() {
    local s=$1
    local buf="" stack="" i=0 n=${#s} ch ch2 q
    local out=""

    while (( i < n )); do
        ch="${s:i:1}"
        case "$ch" in
            "'"|'"')
                q="$ch"; buf+="$ch"; ((i++))
                while (( i < n )); do
                    ch2="${s:i:1}"; buf+="$ch2"; ((i++))
                    if [[ "$ch2" == "\\" ]]; then
                        (( i < n )) && { buf+="${s:i:1}"; ((i++)); }
                        continue
                    fi
                    [[ "$ch2" == "$q" ]] && break
                done
                ;;
            "("|"["|"{")
                stack+="$ch"; buf+="$ch"; ((i++))
                ;;
            ")"|"]"|"}")
                stack="${stack%?}"; buf+="$ch"; ((i++))
                ;;
            ",")
                if [[ -z "$stack" ]]; then
                    # trim
                    buf="${buf#"${buf%%[![:space:]]*}"}"
                    buf="${buf%"${buf##*[![:space:]]}"}"
                    out+="$buf$SEP"
                    buf=""
                else
                    buf+="$ch"
                fi
                ((i++))
                ;;
            *)
                buf+="$ch"; ((i++))
                ;;
        esac
    done
    if [[ -n "$buf" ]]; then
        buf="${buf#"${buf%%[![:space:]]*}"}"
        buf="${buf%"${buf##*[![:space:]]}"}"
        out+="$buf$SEP"
    fi
    printf '%s' "$out"
}

# ---------- extrae el argumento de eval(...)(...) ----------
extract_call_args() {
    local text=$1
    local n=${#text}

    # localizar "eval(function"
    local prefix="${text%%eval(function*}"
    if [[ "$prefix" == "$text" ]]; then
        return 1
    fi
    local pos=${#prefix}
    local i=$pos

    # avanzar hasta el primer '{'
    while (( i < n )) && [[ "${text:i:1}" != "{" ]]; do ((i++)); done
    (( i >= n )) && return 1

    # recorrer cuerpo de la función hasta su '}' de cierre
    local depth=0 found=0
    while (( i < n )); do
        local ch="${text:i:1}"
        case "$ch" in
            "{") ((depth++)); ((i++));;
            "}")
                ((depth--))
                ((i++))
                (( depth == 0 )) && { found=1; break; }
                ;;
            "'"|'"')
                local q="$ch"; ((i++))
                while (( i < n )); do
                    if [[ "${text:i:1}" == "\\" ]]; then ((i+=2)); continue; fi
                    if [[ "${text:i:1}" == "$q" ]]; then ((i++)); break; fi
                    ((i++))
                done
                ;;
            *) ((i++));;
        esac
    done
    (( found == 0 )) && return 1

    # saltar espacios hasta '('
    while (( i < n )) && [[ "${text:i:1}" =~ [[:space:]] ]]; do ((i++)); done
    [[ "${text:i:1}" != "(" ]] && return 1

    # capturar hasta ')' balanceado
    local start=$((i+1)) pdepth=0
    while (( i < n )); do
        local ch="${text:i:1}"
        case "$ch" in
            "(") ((pdepth++)); ((i++));;
            ")")
                ((pdepth--))
                if (( pdepth == 0 )); then
                    printf '%s' "${text:start:$((i-start))}"
                    return 0
                fi
                ((i++))
                ;;
            "'"|'"')
                local q="$ch"; ((i++))
                while (( i < n )); do
                    if [[ "${text:i:1}" == "\\" ]]; then ((i+=2)); continue; fi
                    if [[ "${text:i:1}" == "$q" ]]; then ((i++)); break; fi
                    ((i++))
                done
                ;;
            *) ((i++));;
        esac
    done
    return 1
}

# ---------- two-pass replace ----------
two_pass_replace() {
    local p=$1 a=$2 c=$3
    shift 3
    local -a klist=("$@")

    # placeholders indexados por token base-a
    local -A ph
    local i
    for (( i=0; i<c; i++ )); do
        local tok
        tok=$(num_to_base "$i" "$a")
        ph["$tok"]="__PKG_TOK_${i}__"
    done

    # ordenar tokens por longitud desc (para no romper solapamientos)
    local -a sorted
    mapfile -t sorted < <(
        for k in "${!ph[@]}"; do printf '%s\n' "$k"; done \
        | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-
    )

    local intermediate="$p"
    local k
    for k in "${sorted[@]}"; do
        local esc
        esc=$(printf '%s' "$k" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
        intermediate=$(printf '%s' "$intermediate" | perl -pe "s/(?<![A-Za-z0-9_])${esc}(?![A-Za-z0-9_])/${ph[$k]}/g")
    done

    for (( i=0; i<c; i++ )); do
        local placeholder="__PKG_TOK_${i}__"
        local val=""
        if (( i < ${#klist[@]} )); then
            val="${klist[$i]}"
        fi
        [[ -z "$val" ]] && val=$(num_to_base "$i" "$a")
        intermediate="${intermediate//$placeholder/$val}"
    done

    printf '%s' "$intermediate"
}

# ---------- unpack principal ----------
unpack_payload() {
    local call_args=$1

    # parsear args con separador $SEP
    local raw
    raw=$(parse_top_level_args "$call_args")

    # dividir por $SEP
    local -a args=()
    local tmp="$raw"
    while [[ "$tmp" == *"$SEP"* ]]; do
        args+=("${tmp%%"$SEP"*}")
        tmp="${tmp#*"$SEP"}"
    done
    # último fragmento (si no termina en SEP)
    [[ -n "$tmp" ]] && args+=("$tmp")

    if (( ${#args[@]} < 4 )); then
        echo "Menos de 4 args (encontrados: ${#args[@]})" >&2
        return 1
    fi

    local raw_p="${args[0]}"
    local q="${raw_p:0:1}"
    if [[ "$q" != "'" && "$q" != '"' ]]; then
        echo "Arg[0] no es string: $raw_p" >&2
        return 1
    fi
    local p_inner="${raw_p:1:${#raw_p}-2}"
    local p
    p=$(unescape_js_string "$p_inner")

    local a="${args[1]}"
    local c="${args[2]}"
    local kexpr="${args[3]}"

    # tokens de k
    local -a tokens=()
    if [[ "$kexpr" == \[* ]]; then
        # array literal: extraer cada string entre comillas
        local rest="$kexpr"
        while [[ "$rest" =~ [\'\"]([^\'\"]*)[\'\"] ]]; do
            tokens+=("$(unescape_js_string "${BASH_REMATCH[1]}")")
            rest="${rest#*"${BASH_REMATCH[0]}"}"
        done
    elif [[ "$kexpr" =~ ^[\'\"](.*)[\'\"]\.split\(.*\)$ ]]; then
        local body="${BASH_REMATCH[1]}"
        body=$(unescape_js_string "$body")
        IFS='|' read -ra tokens <<< "$body"
    else
        IFS='|' read -ra tokens <<< "$kexpr"
    fi

    # completar hasta c
    local i
    for (( i=${#tokens[@]}; i<c; i++ )); do
        tokens+=("")
    done

    two_pass_replace "$p" "$a" "$c" "${tokens[@]}"
}

# ---------- main ----------
main() {
    local input="${1:--}"
    local txt
    if [[ "$input" == "-" ]]; then
        txt=$(cat)
    else
        txt=$(cat "$input")
    fi

    local call_args
    if ! call_args=$(extract_call_args "$txt"); then
        echo "No se encontró patrón eval(function...) en el input" >&2
        exit 1
    fi

    unpack_payload "$call_args"
    echo
}

main "$@"
