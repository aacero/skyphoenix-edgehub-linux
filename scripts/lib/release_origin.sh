#!/usr/bin/env bash
#
# Exact remote-tag checks used before a local release can be published.

_xeneon_url_matches_github_repo() {
    local origin_url="$1" repository_slug="$2"
    case "$origin_url" in
        "git@github.com:${repository_slug}.git" \
        |"https://github.com/${repository_slug}" \
        |"https://github.com/${repository_slug}.git" \
        |"ssh://git@github.com/${repository_slug}" \
        |"ssh://git@github.com/${repository_slug}.git")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

xeneon_origin_matches_github_repo() {
    local repo_dir="$1" repository_slug="$2" fetch_url push_url
    fetch_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null)" \
        || return 1
    push_url="$(git -C "$repo_dir" remote get-url --push origin 2>/dev/null)" \
        || return 1
    _xeneon_url_matches_github_repo "$fetch_url" "$repository_slug" || {
        printf 'origin fetch URL does not identify the canonical github.com/%s repository\n' \
            "$repository_slug" >&2
        return 1
    }
    _xeneon_url_matches_github_repo "$push_url" "$repository_slug" || {
        printf 'origin push URL does not identify the canonical github.com/%s repository\n' \
            "$repository_slug" >&2
        return 1
    }
}

xeneon_verify_origin_tag_exact() {
    local repo_dir="$1" tag_name="$2" expected_commit="$3"
    local expected_tag_object="${4:-}"
    local local_type local_tag_object remote_rows remote_tag_object remote_commit

    local_type="$(git -C "$repo_dir" cat-file -t "refs/tags/$tag_name" 2>/dev/null)" \
        || {
            printf 'local tag does not exist: %s\n' "$tag_name" >&2
            return 1
        }
    [ "$local_type" = "tag" ] || {
        printf 'local tag is not annotated: %s\n' "$tag_name" >&2
        return 1
    }
    local_tag_object="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$tag_name")" \
        || return 1
    if [ -n "$expected_tag_object" ] \
            && [ "$local_tag_object" != "$expected_tag_object" ]; then
        printf 'local tag object changed from pinned object %s to %s: %s\n' \
            "$expected_tag_object" "$local_tag_object" "$tag_name" >&2
        return 1
    fi

    command -v timeout >/dev/null 2>&1 || {
        printf 'timeout is required for the remote tag query\n' >&2
        return 1
    }
    remote_rows="$(GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$repo_dir" \
        ls-remote --tags origin \
        "refs/tags/$tag_name" "refs/tags/$tag_name^{}")" \
        || {
            printf 'could not query origin for tag: %s\n' "$tag_name" >&2
            return 1
        }
    remote_tag_object="$(printf '%s\n' "$remote_rows" \
        | awk -v ref="refs/tags/$tag_name" '$2 == ref { print $1 }')"
    remote_commit="$(printf '%s\n' "$remote_rows" \
        | awk -v ref="refs/tags/$tag_name^{}" '$2 == ref { print $1 }')"

    [ -n "$remote_tag_object" ] || {
        printf 'annotated tag is absent from origin: %s\n' "$tag_name" >&2
        return 1
    }
    [ -n "$remote_commit" ] || {
        printf 'origin tag has no annotated-tag peel: %s\n' "$tag_name" >&2
        return 1
    }
    [ "$remote_tag_object" = "${expected_tag_object:-$local_tag_object}" ] || {
        printf 'origin tag object differs from the pinned verified tag: %s\n' "$tag_name" >&2
        return 1
    }
    [ "$remote_commit" = "$expected_commit" ] || {
        printf 'origin tag peels to %s, expected %s: %s\n' \
            "$remote_commit" "$expected_commit" "$tag_name" >&2
        return 1
    }
}
