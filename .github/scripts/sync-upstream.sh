#!/usr/bin/env bash
# 把本 fork 的預設分支與上游預設分支合併。
# 只呼叫 GitHub merge-upstream API。不更新 git ref，不送出 force=true。
# 衝突（HTTP 409）時分支維持原狀，工作流程以失敗結束，並盡量開立議題。

set -euo pipefail

API_URL="${GITHUB_API_URL:-https://api.github.com}"
API_URL="${API_URL%/}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
TOKEN_SOURCE="${SYNC_TOKEN_SOURCE:-GITHUB_TOKEN}"

tmp_files=()
# EXIT trap 才會呼叫；shellcheck 把函式本體看成走不到。
# shellcheck disable=SC2317
cleanup() {
  if ((${#tmp_files[@]} > 0)); then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

annotate() {
  local level="$1"
  local msg="$2"
  msg=${msg//%/%25}
  msg=${msg//$'\n'/%0A}
  msg=${msg//$'\r'/%0D}
  printf '::%s::%s\n' "$level" "$msg"
}

write_summary() {
  local title="$1"
  local body="$2"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## %s\n\n' "$title"
      printf '%s\n' "$body"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

fail() {
  annotate error "$1"
  write_summary "上游同步失敗" "$1"
  exit 1
}

json_message() {
  jq -r '.message // empty' "$1" 2>/dev/null || true
}

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  fail "缺少 GITHUB_TOKEN，無法呼叫 GitHub API。"
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  fail "缺少 GITHUB_REPOSITORY，無法判斷要同步哪一個 fork。"
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  fail "執行環境需要 curl 與 jq。"
fi

# 設定 RESP_CODE 與 RESP_FILE。呼叫端要在下一次 request 前把需要的內容讀完。
request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local body http
  body=$(mktemp)
  tmp_files+=("$body")
  local -a args=(
    -sS
    --max-time 60
    -o "$body"
    -w "%{http_code}"
    -X "$method"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: fork-upstream-sync"
  )
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi
  if ! http=$(curl "${args[@]}" "${API_URL}${path}"); then
    fail "無法連線 GitHub API（${method} ${path}）。"
  fi
  RESP_CODE="$http"
  RESP_FILE="$body"
}

request GET "/repos/${GITHUB_REPOSITORY}"
repo_file="$RESP_FILE"
repo_code="$RESP_CODE"
if [[ "$repo_code" != "200" ]]; then
  fail "讀取儲存庫資訊失敗（HTTP ${repo_code}）：$(json_message "$repo_file")"
fi

is_fork=$(jq -r '.fork // false' "$repo_file")
parent=$(jq -r '.parent.full_name // empty' "$repo_file")
parent_url=$(jq -r '.parent.html_url // empty' "$repo_file")
parent_branch=$(jq -r '.parent.default_branch // empty' "$repo_file")
branch=$(jq -r '.default_branch // empty' "$repo_file")
has_issues=$(jq -r 'if .has_issues then "true" else "false" end' "$repo_file")

if [[ "$is_fork" != "true" || -z "$parent" ]]; then
  fail "此儲存庫不是可同步的 fork（API 沒有回傳上游 parent）。"
fi
if [[ -z "$branch" ]]; then
  fail "找不到本 fork 的預設分支。"
fi

printf '上游：%s（預設分支 %s）\n' "$parent" "${parent_branch:-未知}"
printf '上游網址：%s\n' "$parent_url"
printf '本 fork 預設分支：%s\n' "$branch"
printf '認證來源：%s\n' "$TOKEN_SOURCE"
printf '同步方式：merge-upstream（快轉或 merge commit；衝突則停止）\n'

payload=$(jq -nc --arg branch "$branch" '{branch:$branch}')
request POST "/repos/${GITHUB_REPOSITORY}/merge-upstream" "$payload"
merge_code="$RESP_CODE"
merge_file="$RESP_FILE"
merge_message=$(json_message "$merge_file")
merge_type=$(jq -r '.merge_type // empty' "$merge_file" 2>/dev/null || true)
pretty=$(jq . "$merge_file" 2>/dev/null || cat "$merge_file")
pretty=${pretty:0:4000}

printf 'merge-upstream HTTP %s\n' "$merge_code"
if [[ -n "$merge_type" ]]; then
  printf 'merge_type=%s\n' "$merge_type"
fi
if [[ -n "$merge_message" ]]; then
  printf 'message=%s\n' "$merge_message"
fi

run_url=""
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

ISSUE_NOTE=""

open_issue() {
  local title="$1"
  local body_file="$2"
  if [[ "$has_issues" != "true" ]]; then
    annotate warning "此儲存庫未啟用 Issues，無法自動開立議題。請到 Settings → General → Features 開啟 Issues。這次失敗仍會讓工作流程顯示為失敗。"
    ISSUE_NOTE="此儲存庫尚未啟用 Issues，因此沒有自動開立議題。"
    return 0
  fi

  local existing=""
  request GET "/repos/${GITHUB_REPOSITORY}/issues?state=open&per_page=100"
  if [[ "$RESP_CODE" == "200" ]]; then
    existing=$(jq -r --arg title "$title" '[.[] | select((.title == $title) and ((.pull_request // null) == null))] | .[0].number // empty' "$RESP_FILE" || true)
  else
    annotate warning "無法列出現有議題（HTTP ${RESP_CODE}），改為直接開立新議題。"
  fi

  if [[ -n "$existing" ]]; then
    local comment
    comment=$(jq -nc --rawfile body "$body_file" '{body:$body}')
    request POST "/repos/${GITHUB_REPOSITORY}/issues/${existing}/comments" "$comment"
    if [[ "$RESP_CODE" == "201" ]]; then
      printf '已在既有議題 #%s 補充這次失敗紀錄。\n' "$existing"
      ISSUE_NOTE="已更新議題 #${existing}。"
    else
      annotate warning "無法在議題 #${existing} 留言（HTTP ${RESP_CODE}）：$(json_message "$RESP_FILE")"
      ISSUE_NOTE="既有議題 #${existing} 留言失敗。"
    fi
    return 0
  fi

  local create_payload number
  create_payload=$(jq -nc --arg title "$title" --rawfile body "$body_file" '{title:$title, body:$body}')
  request POST "/repos/${GITHUB_REPOSITORY}/issues" "$create_payload"
  if [[ "$RESP_CODE" == "201" ]]; then
    number=$(jq -r '.number // empty' "$RESP_FILE")
    printf '已開立議題 #%s。\n' "$number"
    ISSUE_NOTE="已開立議題 #${number}。"
  else
    annotate warning "無法開立議題（HTTP ${RESP_CODE}）：$(json_message "$RESP_FILE")"
    ISSUE_NOTE="開立議題失敗（HTTP ${RESP_CODE}）。"
  fi
}

write_issue_body() {
  local heading="$1"
  local guidance="$2"
  local dest="$3"
  {
    printf '%s\n\n' "$heading"
    printf '%s\n' '| 項目 | 內容 |'
    printf '%s\n' '| --- | --- |'
    printf '| 上游 | [%s](%s) |\n' "$parent" "$parent_url"
    printf '| 上游預設分支 | %s |\n' "${parent_branch:-未知}"
    printf '| 本 fork 預設分支 | %s |\n' "$branch"
    printf '| 認證來源 | %s |\n' "$TOKEN_SOURCE"
    if [[ -n "$run_url" ]]; then
      printf '| 執行紀錄 | [這次執行](%s) |\n' "$run_url"
    else
      printf '%s\n' '| 執行紀錄 | （非 GitHub Actions 環境） |'
    fi
    printf '\n%s\n\n' "$guidance"
    printf 'GitHub API 回應（HTTP %s）：\n\n' "$merge_code"
    printf '%s\n' '````json'
    printf '%s\n' "$pretty"
    printf '%s\n\n' '````'
    printf '%s\n' '之後若相同情況還在，排程會在這則議題補上留言，不會另開一則。'
  } >"$dest"
}

case "$merge_code" in
  200)
    case "$merge_type" in
      fast-forward)
        result="已快轉 ${branch}，與上游 ${parent} 的 ${parent_branch:-預設分支} 對齊。"
        ;;
      merge)
        result="已建立 merge commit，把上游 ${parent} 合併進 ${branch}。本 fork 自己的提交與檔案都保留。"
        ;;
      none)
        result="${branch} 已與上游 ${parent} 一致。"
        ;;
      *)
        result="merge-upstream 回傳成功（merge_type=${merge_type:-未知}）。${merge_message}"
        ;;
    esac
    printf '%s\n' "$result"
    write_summary "上游同步完成" "$(
      printf '%s\n\n' "$result"
      printf -- '- 上游：[%s](%s)\n' "$parent" "$parent_url"
      printf -- '- 分支：%s\n' "$branch"
      printf -- '- 方式：%s\n' "${merge_type:-unknown}"
      printf -- '- 認證：%s\n' "$TOKEN_SOURCE"
    )"
    exit 0
    ;;
  409)
    issue_body=$(mktemp)
    tmp_files+=("$issue_body")
    write_issue_body \
      "自動同步上游時發生合併衝突，這次同步已停止。預設分支維持執行前的內容，本 fork 自己的檔案都還在。" \
      "請把上游合併進預設分支，解決衝突後再推送。請用合併保留兩邊的檔案。\`git push --force\` 與 \`gh repo sync --force\` 會改寫本 fork 已有的歷史，請勿使用。" \
      "$issue_body"
    open_issue "上游同步發生合併衝突" "$issue_body"
    fail "合併衝突（HTTP 409）。${branch} 維持執行前的內容。${ISSUE_NOTE}"
    ;;
  *)
    guidance="請依 API 回應排查。同步中途失敗時，這個腳本不會改寫分支。"
    title="上游同步失敗"
    if printf '%s' "$merge_message" | grep -qi 'workflow'; then
      title="上游同步需要 workflows 權限"
      if [[ "$TOKEN_SOURCE" == "GITHUB_TOKEN" ]]; then
        guidance="上游這批提交改到了 .github/workflows。GITHUB_TOKEN 沒有 workflows 權限，而且 workflow 的 permissions 區塊也無法補上這項權限，所以 GitHub 回絕合併。預設分支維持執行前的內容。

可以擇一處理：

1. 用瀏覽器打開本 fork，在預設分支按 Sync fork。GitHub 會合併上游；若有衝突，會改請你開 pull request，不會強制覆蓋。
2. 建立一組只限本儲存庫的 fine-grained personal access token，權限為 Contents、Workflows、Issues 皆讀寫，存成 Actions secret，名稱為 UPSTREAM_SYNC_TOKEN。下次排程會自動改用它，不必再改這個工作流程。Issues 權限是為了在失敗時開立議題。

請用合併保留本 fork 已有的檔案，不要使用 git push --force 或 gh repo sync --force。"
      else
        guidance="目前使用 UPSTREAM_SYNC_TOKEN，但 GitHub 仍拒絕合併含有 workflow 檔案的上游提交。請確認這組 token 是只限本儲存庫的 fine-grained PAT，且 Contents、Workflows、Issues 都是讀寫。預設分支維持執行前的內容。請用合併處理，不要使用 git push --force 或 gh repo sync --force。"
      fi
    fi
    issue_body=$(mktemp)
    tmp_files+=("$issue_body")
    write_issue_body \
      "自動同步上游沒有完成，預設分支維持執行前的內容。" \
      "$guidance" \
      "$issue_body"
    open_issue "$title" "$issue_body"
    fail "上游同步失敗（HTTP ${merge_code}）：${merge_message} ${ISSUE_NOTE}"
    ;;
esac
