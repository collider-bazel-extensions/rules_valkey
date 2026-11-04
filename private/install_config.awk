# Replace the data of the chart's ConfigMap `cm_name` in a rendered
# manifest with <first_key> (+ any further files, keyed by basename).
#
#   awk -v cm_name=NAME -v first_key=KEY -v ndata=N -f install_config.awk \
#       config [file...] manifest.yaml > out.yaml
#
# The first N files are the data (the first one is stored under the key
# first_key, the rest under their basenames) and become YAML
# literal blocks; the last file is the manifest. Every other document
# passes through unchanged. Exits 2 unless exactly one ConfigMap named
# cm_name is found.

function flush_doc(    i, j) {
    if (ndoc == 0) return
    if (doc_kind == "ConfigMap" && doc_name == cm_name) {
        found++
        for (i = 1; i <= ndoc && doc[i] !~ /^data:/; i++) print doc[i]
        print "data:"
        printf "%s", data_block
        # Copy any top-level keys that follow the data block.
        for (j = i + 1; j <= ndoc; j++)
            if (doc[j] ~ /^[^ #]/) break
        for (; j <= ndoc; j++) print doc[j]
    } else {
        for (i = 1; i <= ndoc; i++) print doc[i]
    }
    ndoc = 0; doc_kind = ""; doc_name = ""; in_meta = 0
}

FNR == 1 { file_index++ }

file_index <= ndata {
    if (FNR == 1) {
        n = split(FILENAME, parts, "/")
        key = (file_index == 1) ? first_key : parts[n]
        data_block = data_block "  " key ": |\n"
    }
    data_block = data_block (length($0) ? "    " $0 : "") "\n"
    next
}

/^---/ { flush_doc(); print; next }
{
    doc[++ndoc] = $0
    if ($0 ~ /^kind: /) doc_kind = substr($0, 7)
    if ($0 ~ /^metadata:/) in_meta = 1
    else if ($0 ~ /^[^ ]/) in_meta = 0
    if (in_meta && $0 ~ /^  name: /) doc_name = substr($0, 9)
}

END {
    flush_doc()
    if (found != 1) {
        printf "install_config: expected one ConfigMap %s, found %d\n", cm_name, found > "/dev/stderr"
        exit 2
    }
}
