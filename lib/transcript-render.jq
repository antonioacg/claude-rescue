# Lines $from..$to (1-based, inclusive) of a Claude Code transcript, readable:
# messages in full, tool calls and results clipped (read a line whole with
# jq -c 'select(input_line_number == N)' transcript.jsonl), compactions marked.
def clip($n): if length > $n then .[0:$n] + " …[\(length - $n) more chars]" else . end;
def text_of:
  if type == "string" then .
  elif type == "array" then
    map(if .type == "text" then .text
        elif .type == "thinking" then "[thinking] " + ((.thinking // "") | clip(1500))
        elif .type == "tool_use" then "[tool_use \(.name)] " + (.input | tojson | clip(1500))
        elif .type == "tool_result" then "[tool_result] "
          + ((.content | if type == "string" then . elif type == "array" then map(.text? // "") | join(" ") else tostring end) | clip(1500))
        else empty end) | join("\n")
  else "" end;
select(input_line_number >= $from and input_line_number <= $to)
| select(.type == "user" or .type == "assistant" or .type == "system" or .type == "summary")
| "#\(input_line_number) \(.timestamp // "") \(.type)"
  + (if .isCompactSummary == true then " [COMPACTION SUMMARY]" else "" end)
  + (if .subtype == "compact_boundary" then " [COMPACTION BOUNDARY]" else "" end)
  + "\n" + ((.message.content // .summary // .content // "") | text_of) + "\n"
