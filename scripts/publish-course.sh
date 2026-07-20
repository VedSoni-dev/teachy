#!/bin/bash
set -euo pipefail

# =============================================================================
# publish-course.sh — Ship a course to the public Teachy course store
#
# Copies a course JSON into the public teachy-releases repo and upserts its
# entry in registry.json, so it appears in the app's Academy section and on
# the website store (academy/courses.html) immediately — no app release needed.
#
# Usage:
#   ./scripts/publish-course.sh courses/my-course.json
#   ./scripts/publish-course.sh courses/my-course.json --blurb "One-liner for the store card" --track "How to do" --featured
#
# Registry fields are derived from the course JSON (id, title, subtitle,
# estimatedMinutes, goal count). --blurb / --track / --featured / --author
# set the store-only fields. Re-running with the same course id UPDATES the
# existing entry and course file (that's how you ship course fixes).
# =============================================================================

RELEASES_REPO="VedSoni-dev/teachy-releases"
RAW_BASE="https://raw.githubusercontent.com/${RELEASES_REPO}/main"

COURSE_FILE="${1:-}"
if [ -z "${COURSE_FILE}" ] || [ ! -f "${COURSE_FILE}" ]; then
    echo "Usage: ./scripts/publish-course.sh path/to/course.json [--blurb \"...\"] [--track \"...\"] [--author \"...\"] [--featured]"
    exit 1
fi
shift

BLURB=""
TRACK=""
AUTHOR="Teachy"
FEATURED="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --blurb) BLURB="$2"; shift 2 ;;
        --track) TRACK="$2"; shift 2 ;;
        --author) AUTHOR="$2"; shift 2 ;;
        --featured) FEATURED="true"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate the course JSON and pull the fields the registry needs.
COURSE_META=$(python3 - "$COURSE_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    course = json.load(f)
for required in ("id", "title", "goals"):
    if required not in course:
        sys.exit(f"Course JSON missing required field: {required}")
print(json.dumps({
    "id": course["id"],
    "title": course["title"],
    "subtitle": course.get("subtitle", ""),
    "estimatedMinutes": course.get("estimatedMinutes", 30),
    "goalCount": len(course["goals"]),
}))
PY
)
COURSE_ID=$(echo "${COURSE_META}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

echo "📚 Publishing course '${COURSE_ID}' to ${RELEASES_REPO}…"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --quiet --depth 1 "https://github.com/${RELEASES_REPO}.git" "${WORK_DIR}/repo"
cd "${WORK_DIR}/repo"

mkdir -p courses
cp "${OLDPWD}/${COURSE_FILE}" "courses/${COURSE_ID}.json" 2>/dev/null \
    || cp "${COURSE_FILE}" "courses/${COURSE_ID}.json"

# Upsert the registry entry, preserving hand-edited fields (blurb/track/
# featured/author survive unless explicitly re-passed).
python3 - "${COURSE_META}" "${RAW_BASE}" "${BLURB}" "${TRACK}" "${AUTHOR}" "${FEATURED}" <<'PY'
import json, sys
course_meta = json.loads(sys.argv[1])
raw_base, blurb, track, author, featured = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

with open("registry.json") as f:
    registry = json.load(f)

courses = registry.setdefault("courses", [])
existing = next((entry for entry in courses if entry.get("id") == course_meta["id"]), None)

entry = existing if existing is not None else {}
entry.update({
    "id": course_meta["id"],
    "title": course_meta["title"],
    "subtitle": course_meta["subtitle"],
    "estimatedMinutes": course_meta["estimatedMinutes"],
    "goalCount": course_meta["goalCount"],
    "installURL": f"{raw_base}/courses/{course_meta['id']}.json",
    "hasVideoParts": entry.get("hasVideoParts", False),
    "shipsWithApp": entry.get("shipsWithApp", False),
})
entry.setdefault("authorName", author)
entry.setdefault("authorHandle", author.lower().replace(" ", ""))
if blurb:
    entry["blurb"] = blurb
if track:
    entry["trackTitle"] = track
if featured == "true":
    entry["featured"] = True
if existing is None:
    courses.append(entry)

with open("registry.json", "w") as f:
    json.dump(registry, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"   registry.json: {'updated' if existing is not None else 'added'} entry for {course_meta['id']}")
PY

git add "courses/${COURSE_ID}.json" registry.json
if git diff --cached --quiet; then
    echo "✅ Nothing changed — course already published at this exact content."
    exit 0
fi
git -c user.name="Teachy Publisher" -c user.email="nilayrsoni@gmail.com" \
    commit --quiet -m "Publish course: ${COURSE_ID}"
git push --quiet origin main

echo ""
echo "✅ Course '${COURSE_ID}' is live:"
echo "   Install URL: ${RAW_BASE}/courses/${COURSE_ID}.json"
echo "   Store:       shows on academy/courses.html + in-app Academy on next refresh"
echo "   Deep link:   teachy://install?url=${RAW_BASE}/courses/${COURSE_ID}.json"
