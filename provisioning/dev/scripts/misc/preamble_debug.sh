set -euo pipefail
echo "DEBUG BASH_SOURCE:" >&2
for i in "${!BASH_SOURCE[@]}"; do echo "  [$i] = ${BASH_SOURCE[$i]:-UNSET}" >&2; done
