#!/bin/bash

# Read the shipped INI strings as data; never execute translation values.
declare -A I915_MESSAGES=()
I915_I18N_DIR="${TRIM_APPDEST:-}/app/i18n"
if [[ ! -r "${I915_I18N_DIR}/en" ]]; then
    I915_I18N_DIR="$(dirname -- "${BASH_SOURCE[0]}")/../i18n"
fi
I915_LANGUAGE=${TRIM_SYS_LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}}
case "${I915_LANGUAGE,,}" in
    zh|zh-*|zh_*) I915_LANGUAGE=zh ;;
    *) I915_LANGUAGE=en ;;
esac

i915_load_messages() {
    local file=$1
    local line section key value

    [[ -r "$file" ]] || return 1
    section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        case "$line" in
            \[*\]) section=$line ;;
            *=*)
                [[ "$section" == "[runtime]" ]] || continue
                key=${line%%=*}
                value=${line#*=}
                [[ "$key" =~ ^[a-z][a-z0-9_]*$ && "$value" == \"*\" ]] || continue
                value=${value#\"}
                value=${value%\"}
                I915_MESSAGES["$key"]=$value
                ;;
        esac
    done < "$file"
}

# English supplies the fallback for unsupported locales and missing translations.
i915_load_messages "${I915_I18N_DIR}/en" || return 1
if [[ "$I915_LANGUAGE" == zh ]]; then
    i915_load_messages "${I915_I18N_DIR}/zh" || true
fi

i915_message() {
    local key=$1
    shift

    printf -- "${I915_MESSAGES[$key]:-$key}" "$@"
    printf '\n'
}
