#!/bin/zsh

FZF_DBT_PATH=$0

# A jq filter that simplifies the dbt manifest json and only keeps
# the keys we need.
JQ_DBT_MODEL_FILTER='
    .nodes |
    to_entries |
    map({
        model: .value.name,
        resource_type: .value.resource_type,
        file_path: (.value.root_path + "/" + .value.original_file_path),
        package_path: (.value.fqn[:-1] | join(".") ), tags: .value.tags
    }) |
    .[] |
    select(.resource_type == "model")
'


# Walk up the filesystem until we find a dbt_project.yml file,
# then return the path which contains it (if found).
# Taken from the _dbt zsh completion script:
# https://github.com/dbt-labs/dbt-completion.bash/blob/master/_dbt
_dbt_fzf_get_project_root() {
  slashes=${PWD//[^\/]/}
  directory="$PWD"
  for (( n=${#slashes}; n>0; --n ))
  do
    test -e "$directory/dbt_project.yml" && echo "$directory" && return
    directory="$directory/.."
  done
}


# Prints path of the dbt manifest.json
_dbt_fzf_get_manifest_path() {
    local project_dir=$(_dbt_fzf_get_project_root)
    if [ -z "$project_dir" ]
    then
        return
    fi

    echo "${project_dir}/target/manifest.json"
}


# Prints a list of all dbt models
_dbt_fzf_get_model_list() {
    local manifest_path=$(_dbt_fzf_get_manifest_path)

    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    jq -r "$JQ_DBT_MODEL_FILTER | .model" $manifest_path | sort
}

# Prints a list of all dbt tags
_dbt_fzf_get_tag_list() {
    local manifest_path=$(_dbt_fzf_get_manifest_path)

    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    jq -r "$JQ_DBT_MODEL_FILTER | (\"tag:\" + .tags[])" $manifest_path \
    | sort | uniq
}

# Prints a list of all dbt package paths
_dbt_fzf_get_package_paths() {
    local manifest_path=$(_dbt_fzf_get_manifest_path)

    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    local package_list=$(
        jq -r "$JQ_DBT_MODEL_FILTER | .package_path" $manifest_path \
        | sort | uniq
    )

    echo $package_list | awk '{
        parts_len=split($0, parts, ".");
        for(part = 1; part <= parts_len; part++) {
            path = "";
            for(i = 1; i<= part; i++) {
                printf("%s", parts[i]);

                if(i == part) {
                    printf("\n");
                } else {
                    printf(".");
                }
            }
        }
    };' \
    | sort | uniq
}

# Returns the file path of a model
_dbt_fzf_get_path_for_model() {
    local model_name=$1

    if [ -z "$model_name" ]
    then
        echo "No model name specified in first arg."
        return
    fi

    local manifest_path=$(_dbt_fzf_get_manifest_path)

    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi


    local model_path=$(
        jq \
            "
                $JQ_DBT_MODEL_FILTER | 
                select(.model == \"$model_name\") |
                .file_path
            " \
            $manifest_path
    )

    echo $model_path
}

# Prints all models that have the tag that is supplied in the first argument
_dbt_fzf_get_models_for_tag() {
    local tag_name=$1

    if [ -z "$tag_name" ]
    then
        echo "No tag name specified in first arg."
        return
    fi

    # Remove "tag:" prefix if present
    if [[ $tag_name == tag:* ]]
    then
        tag_name=$(echo $tag_name | cut -c 5-)
    fi

    local manifest_path=$(_dbt_fzf_get_manifest_path)
    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    jq \
        -r \
        "
            $JQ_DBT_MODEL_FILTER |
            select(.tags[] | contains (\"$tag_name\")) |
            .model
        " \
        $manifest_path \
    | sort 
}

# Prints all models that are within the package path that is supplied
# in the first argument.
_dbt_fzf_get_models_for_package_path() {
    local package_path=$1

    if [ -z "$package_path" ]
    then
        echo "No package path specified in first arg."
        return
    fi

    local manifest_path=$(_dbt_fzf_get_manifest_path)
    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    jq \
        -r \
        "
            $JQ_DBT_MODEL_FILTER |
            select(.package_path|startswith(\"$package_path\")) |
            .model
        " \
        $manifest_path \
    | sort 
}

# Tries to find a list of models for the selection.
# First tries to check if the selection is a tag and looks for
# all models that have that tag.
# Then tries to treat the selection as a package path and looks for
# all models within that package path.
_dbt_fzf_get_models_for_selection() {
    local fzf_selection=$1

    local selection_models=""

    # If the selection starts with "tag:", try to get all models
    # that have that tag applied
    if [[ $fzf_selection == tag:* ]]
    then
        selection_models=$(
            _dbt_fzf_get_models_for_tag $fzf_selection
        )
    fi

    # If we didn't find models using the tag search, try the 
    # package path search
    if [ -z "$selection_models" ]
    then
        selection_models=$(
            _dbt_fzf_get_models_for_package_path $fzf_selection
        )
    fi

    # If we still couldn't find any models, then try to use `dbt ls`
    # to get the models for the selections.
    # This is slower, but allows us to find models even for selectors 
    # that use "+"" and "@" modifiers.
    if [ -z "$selection_models" ]
    then
        selection_models=$(
            dbt ls -m "$fzf_selection" \
            | awk '{ n=split($1, part, "."); print part[n] }'
        )
    fi

    echo $selection_models
}

# These functions return selection lists for fzf.
# The first line of these methods is used as the header in fzf.
_dbt_fzf_show_models() {
    echo "\033[0;31m[models - ,]\033[0m   [selectors - .]"
    _dbt_fzf_get_model_list
}

_dbt_fzf_show_models_plus() {
    echo "\033[0;31m[models+ - <]\033[0m   [selectors - .]"
    local model_list=$(_dbt_fzf_get_model_list)
    
    (
        echo $model_list
        echo $model_list | awk '{print "+" $0;}'
        echo $model_list | awk '{print $0 "+";}'
        echo $model_list | awk '{print "+" $0 "+";}'
        echo $model_list | awk '{print "@" $0;}'

        for i in {1..3}
        do
            echo $model_list | awk -v i="$i" '{print i "+" $0;}'
            echo $model_list | awk -v i="$i" '{print $0 "+" i;}'
        done
    ) | sort
}

_dbt_fzf_show_selectors() {
    echo "[models - ,]   \033[0;31m[selectors - .]\033[0m"
    (
        _dbt_fzf_get_tag_list
        _dbt_fzf_get_package_paths
    )
}

# This is the actual function called to launch fzf when you type **<tab>
_fzf_complete_dbt() {
    local height=${FZF_DBT_HEIGHT-80%}
    _fzf_complete \
        --multi \
        --reverse \
        --prompt="dbt> " \
        --bind=",:reload( source $FZF_DBT_PATH; _dbt_fzf_show_models )" \
        --bind="<:reload( source $FZF_DBT_PATH; _dbt_fzf_show_models_plus )" \
        --bind=".:reload( source $FZF_DBT_PATH; _dbt_fzf_show_selectors )" \
        --header-lines=1 \
        --preview "source $FZF_DBT_PATH;  _dbt_fzf_preview {}" \
        --height $height \
        -- "$@" \
        < <( _dbt_fzf_show_models )
}


# This function generates the preview command inside fzt.
#
# You can adjust the command that will be used to output the model
# code by setting the environment variable `FZF_DBT_PREVIEW_CMD`.
#
# You can use `{}` to specify where the file path of the model will be
# inserted.
#
# For example, you can use `bat` to get a syntax highlighted preview:
# `export FZF_DBT_PREVIEW_CMD='bat --theme OneHalfLight --color=always
# --style=numbers {}'`

_dbt_fzf_preview() {
    local fzf_selection=$1
    local preview_cmd=${FZF_DBT_PREVIEW_CMD-"cat {}"}
    local manifest_path=$(_dbt_fzf_get_manifest_path)

    if [ -z "$fzf_selection" ]
    then
        echo "No dbt fzf_selection specified for preview."
        return
    fi

    if [ -z "$manifest_path" ]
    then
        echo "No dbt project at the current path."
        return
    fi

    local final_preview_cmd=""

    # Try to get a model path for the selection
    local model_path=$(_dbt_fzf_get_path_for_model $fzf_selection)

    # If we found a model path, then show the model content as the preview
    if [ ! -z "$model_path" ]
    then
        final_preview_cmd=${preview_cmd//"{}"/$model_path}
    fi

    # If no model path was found, try to get a list of models for
    # the fzf selection and display it
    if [ -z "$final_preview_cmd" ]
    then

        local selection_models=$(
            _dbt_fzf_get_models_for_selection $fzf_selection
        )

        # Add line numbers before models
        local selection_models_numbered=$(
            echo $selection_models \
            | awk '{ printf( "\t%002d) %s\n", NR, $0 ) }'
        )

        # Count models
        local model_count=$(echo "$selection_models" | wc -l | xargs)

        # Generate a preview command that shows all models within selection
        final_preview_cmd="
            echo 'Selection \"$fzf_selection\" contains $model_count models...\n\n$selection_models_numbered'
        "
    fi

    # If no preview cmd could be generated, show error message
    if [ -z "$final_preview_cmd" ]
    then
        final_preview_cmd=(
            "echo 'Could not generate a preview for selection \"$fzf_selection\" '"
        )
    fi

    # Run the preview command
    zsh -c "$final_preview_cmd"
}
