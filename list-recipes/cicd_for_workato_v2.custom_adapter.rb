{
  title: "Workato Developer APIs",

  connection: {
    fields: [ 
      {
        name: "workato_environments",
        label: "Workato environments",
        item_label: "Environment",
        list_mode: "static",
        list_mode_toggle: false,
        type: "array",
        of: "object",
        properties: [            
          {
            name: "name",
            label: "Environment name",
            optional: false,
            hint: "Workato environment identifier. For example, DEV, TEST, or PROD."
          },    
          {
            name: "data_center",
            label: "Data center",
            control_type: "select",
            default: "https://www.workato.com/api",
            optional: false,
            options: [
              ["US", "https://www.workato.com/api"],
              ["EU", "https://app.eu.workato.com/api"],
              ["SG", "https://app.sg.workato.com/api"],
              ["JP", "https://app.jp.workato.com/api"],
              ["AU", "https://app.au.workato.com/api"]
            ]
          },
          {
            name: "email",
            label: "Email address",
            optional: true,
            hint: "Required only for legacy API key validation. Email address to access Workato platform APIs."
          },

          {
            name: "api_key",
            label: "API key",
            control_type: "password",
            optional: false,
            hint: "You can find your API key in the <a href=\"https://www.workato.com/users/current/edit#api_key\" target=\"_blank\">settings page</a>."
          }         
        ]
      }
    ],

    authorization: {
      type: "custom_auth",
    },


  },

  test: lambda do |connection|
    connection["workato_environments"].each do |env|

      if env["email"].present?
        connect_res = get("#{env['data_center']}/users/me")
        .headers({ "x-user-email": "#{env["email"]}",
          "x-user-token": "#{env["api_key"]}" })
        connect_res.presence
      elsif
        connect_res = get("#{env['data_center']}/users/me")
        .headers({ "Authorization": "Bearer #{env["api_key"]}" })
        connect_res.presence
      end

    end   
  end,

  object_definitions: {
    package_details: {
      fields: lambda do
        [
          {
            name: "workato_environment",
            label: "Workato environment"
          },
          {
            name: "package_id",
            label: "Package ID"
          },
          {
            name: "api_mode",
            label: "API Mode"
          },           
          {
            name: "content",
            label: "Package content"
          }           
        ]
      end
    }, # package_details.end    
   
    list_customer_accounts_output: {
      fields: lambda do |_connection, _config_fields|
        [
          { name: 'result', label: 'Customer accounts',
            type: 'array', of: 'object',
            properties: call('customer_accounts_output_schema').
              ignored('member_id', 'oauth_id', 'role_name',
                      'page', 'per_page', 'custom_task_limit',
                      'billing_start_date') }
        ]
      end
    }, #list_customer_accounts_output.end
  },

  actions: {
    build_download_package: {
      title: "Build and download package",
      subtitle: "Build and download manifest or a project",

      help: "Use this action to build and export a manifest or project from the selected environment.",

      description: lambda do |input| 
        "Build and download <span class='provider'>package</span> from " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        [ 
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },                        
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            ngIf: "input.api_mode == 'rlcm'",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },          
          {
            name: "id",
            label: "ID",
            hint: "Source manifest or project/folder ID to build.",
            optional: false
          },
          {
            name: "description",
            label: "Description",
            hint: "Release description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }          
        ]
      end,      

      execute: lambda do |connection, input, eis, eos, continue|

        continue = {} unless continue.present?
        current_step = continue['current_step'] || 1
        max_steps = 10
        step_time = current_step * 10 # This helps us wait longer and longer as we increase in steps
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end        

        if current_step == 1 # First invocation
          # Projects API - https://docs.workato.com/workato-api/projects.html#build-a-project
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#export-package-based-on-a-manifest
          build_endpoint = projects ? "#{env_datacenter}/projects/f#{input["id"]}/build" : "#{env_datacenter}/packages/export/#{input["id"]}"
          build_body = projects ? { description:input["description"].to_s } : ""

          response = post(build_endpoint)
          .headers(headers)
          .request_body(build_body)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")

          # If job is in_progress, reinvoke after wait time
          if res_in_progress == true
            reinvoke_after(
              seconds: step_time, 
              continue: { 
                current_step: current_step + 1, 
                jobid: response['id']
              }
            )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            call("download_from_url", {
              "headers" => headers, 
              "workato_environment" => input["workato_environment"],
              "download_url" => response["download_url"],
              "package_id" => response["id"],
              "api_mode" => input["api_mode"]
            })
          end # first_response_if.end

          # Subsequent invocations
        elsif current_step <= max_steps                 
          # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-project-build
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
          status_endpoint = projects ? "/project_builds/#{continue["jobid"]}" : "/packages/#{continue["jobid"]}"

          response = get(status_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")

          if res_in_progress
            reinvoke_after(
              seconds: step_time, 
              continue: { 
                current_step: current_step + 1, 
                jobid: response['id']
              }
            )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            call("download_from_url", {
              "headers" => headers, 
              "workato_environment" => input["workato_environment"],
              "download_url" => response["download_url"],
              "package_id" => response["id"],
              "api_mode" => input["api_mode"]              
            })
          end # subsequent_response_if.end

        else
          error("Job took too long!")

        end # outer.if.end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        object_definitions["package_details"]
      end # output_fields.end

    }, # build_download_package.end
    build_package_async: {
      title: "Build package (Asynchronous)",
      subtitle: "Build manifest or a project Async",

      help: "Use this action to trigger build manifest or project from the selected environment.",

      description: lambda do |input| 
        "Build <span class='provider'>package</span> from " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        [ 
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },                        
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            ngIf: "input.api_mode == 'rlcm'",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },          
          {
            name: "id",
            label: "ID",
            hint: "Source manifest or project/folder ID to build.",
            optional: false
          },
          {
            name: "description",
            label: "Description",
            hint: "Release description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }          
        ]
      end,      

      execute: lambda do |connection, input, eis, eos, continue|


        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end        


        # Projects API - https://docs.workato.com/workato-api/projects.html#build-a-project
        # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#export-package-based-on-a-manifest
        build_endpoint = projects ? "#{env_datacenter}/projects/f#{input["id"]}/build" : "#{env_datacenter}/packages/export/#{input["id"]}"
        build_body = projects ? { description:input["description"].to_s } : ""

        response = post(build_endpoint)
        .headers(headers)
        .request_body(build_body)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end

        res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
        res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
        res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")
        {
          job_id: response["id"]
        }


      end, # execute.end

      output_fields: lambda do |conenction|
        [ 

          { name: "job_id" },
        ]
      end # output_fields.end

    }, # buils_package_async.end    
    download_package: {
      title: "Download package",
      subtitle: "Download existing package from Workato",

      help: "Use this action to download a package from the selected environment.",

      description: lambda do |input| 
        "Download <span class='provider'>package</span> from " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        [  
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },                       
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            ngIf: "input.api_mode == 'rlcm'",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },          
          {
            name: "id",
            label: "ID",
            hint: "Package or build ID to export.",
            optional: false            
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end

        # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-project-build
        # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
        status_endpoint = projects ? "#{env_datacenter}/project_builds/#{input["id"]}" : "#{env_datacenter}/packages/#{input["id"]}"

        response = get(status_endpoint)
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end        

        if response["status"] == "completed" 
          call("download_from_url", {
            "headers" => headers, 
            "workato_environment" => input["workato_environment"],
            "download_url" => response["download_url"],
            "package_id" => response["id"],
            "api_mode" => input["api_mode"]              
          })

        end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        object_definitions["package_details"]
      end # output_fields.end      

    }, # download_package.end
    deploy_package: {
      title: "Deploy package",
      subtitle: "Deploy package to Workato environment",

      help: "Use this action import a package to the selected environment. This is a synchronous request and uses Workato long action. Learn more <a href=\"https://docs.workato.com/workato-api/recipe-lifecycle-management.html#import-package-into-a-folder\" target=\"_blank\">here</a>.",

      description: lambda do |input| 
        "Deploy <span class='provider'>package</span> to " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        mode = config_fields['api_mode']       
        [
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },          
          {
            name: "id",
            label: "ID",
            hint: "Package or build ID to deploy.",
            optional: false
          }, 
          { 
            name: "workato_src_environment",
            label: "Source environment",
            hint: "Select Workato DEV environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            pick_list: "environments"
          },   
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.api_mode == 'customer'",
            optional: true
          },             
          { 
            name: "workato_environment",
            label: "Target environment",
            hint: "Select target Workato environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          {
            name: "folder_id",
            label: "Folder ID",
            hint: "Target environment folder ID to import package into.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true
          },                      
          {
            name: "env_type",
            label: "Environment type",
            hint: "Target environment type. Projects API currently supports only test and prod values.",
            control_type: "select",
            pick_list: "env_type",
            ngIf: "input.api_mode == 'projects'",            
            optional: true
          },
          {
            name: "description",
            label: "Description",
            hint: "Deployment description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }                                                 
        ]
      end,

      execute: lambda do |connection, input, eis, eos, continue|
        continue = {} unless continue.present?
        current_step = continue['current_step'] || 1
        max_steps = 10
        step_time = current_step * 5 # This helps us wait longer and longer as we increase in steps

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        projects = true
        if(input["api_mode"] == "rlcm" || input["api_mode"] == "customer" )  
          projects = false
        end # api_mode_if.end               

        if current_step == 1 # First invocation
          # Projects API - https://docs.workato.com/workato-api/projects.html#deploy-a-project-build
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#export-package-based-on-a-manifest

          if input["api_mode"] == "rlcm"
            deploy_endpoint = "#{env_datacenter}/packages/import/#{input["folder_id"]}?restart_recipes=true"
          elsif input["api_mode"] == "project"
            deploy_endpoint = "#{env_datacenter}/project_builds/#{input["id"]}/deploy?environment_type=#{input["env_type"]}" 
          else 
            deploy_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/imports?folder_id=#{input["folder_id"]}&restart_recipes=true"
          end

          # For RLCM API, download package ID and use it for import
          deploy_body = ""
          if projects
            deploy_body = { "description" => input["description"].to_s }
            headers["Content-Type"] = "application/json"
          else
            src_env_headers = call("get_auth_headers", connection, "#{input["workato_src_environment"]}")
            deploy_body = get("#{env_datacenter}/packages/#{input["id"]}/download")
            .headers(src_env_headers).headers("Accept": "*/*")
            .after_error_response(/.*/) do |_code, body, _header, message|
              error("#{message}: #{body}")
            end.response_format_raw.encode('ASCII-8BIT')
            headers["Content-Type"] = "application/octet-stream"
          end

          response = post(deploy_endpoint) 
          .headers(headers)
          .request_body(deploy_body)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")          

          # If job is in_progress, reinvoke after wait time
          if res_in_progress
            reinvoke_after(
              seconds: step_time, 
              continue: { 
                current_step: current_step + 1, 
                jobid: response['id']
              }
            )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)            
          elsif res_success
            {
              status: projects ? response["state"] : response["status"],
              job_id: response["id"]
            }
          end # first_response_if.end

          # Subsequent invocations
        elsif current_step <= max_steps           
          # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-deployment
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
          status_endpoint = ""
          if input["api_mode"] == "rlcm"
            status_endpoint = "#{env_datacenter}/packages/#{continue["jobid"]}"
          elsif input["api_mode"] == "project"
            status_endpoint = "#{env_datacenter}/deployments/#{continue["jobid"]}"
          else 
            status_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/imports/#{continue["jobid"]}"
          end

          response = get(status_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")               

          if res_in_progress
            reinvoke_after(
              seconds: step_time, 
              continue: { 
                current_step: current_step + 1, 
                jobid: response["id"]
              }
            )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            {
              status: projects ? response["state"] : response["status"],
              job_id: response["id"]
            }
          end # subsequent_response_if.end

        else
          error("Job #{continue["jobid"]} took too long!")          

        end # outer.if.end

      end, # execute.end

      output_fields: lambda do |connection|
        [ 
          { name: "status" },
          { name: "job_id" },
        ]
      end
    }, # deploy_package.end
    deploy_package_async: {
      title: "Deploy package (Asynchronous)",
      subtitle: "Deploy package to Workato environment, returns job id",

      help: "Use this action import a package to the selected environment. This is an asynchronous request and will return job id. Learn more <a href=\"https://docs.workato.com/workato-api/recipe-lifecycle-management.html#import-package-into-a-folder\" target=\"_blank\">here</a>.",

      description: lambda do |input| 
        "Deploy <span class='provider'>package</span> to " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span> Asynchronously"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        mode = config_fields['api_mode']       
        [
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },          
          {
            name: "id",
            label: "ID",
            hint: "Package or build ID to deploy.",
            optional: false
          }, 
          { 
            name: "workato_src_environment",
            label: "Source environment",
            hint: "Select Workato DEV environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            toggle_hint: "Custom Value",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_src_environment",
              label: "Workato Source environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },   
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.api_mode == 'customer'",
            optional: true
          },             
          { 
            name: "workato_environment",
            label: "Target environment",
            hint: "Select target Workato environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          {
            name: "folder_id",
            label: "Folder ID",
            hint: "Target environment folder ID to import package into.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true
          },                      
          {
            name: "env_type",
            label: "Environment type",
            hint: "Target environment type. Projects API currently supports only test and prod values.",
            control_type: "select",
            pick_list: "env_type",
            ngIf: "input.api_mode == 'projects'",            
            optional: true
          },
          {
            name: "description",
            label: "Description",
            hint: "Deployment description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }                                                 
        ]
      end,

      execute: lambda do |connection, input, eis, eos, continue|

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        projects = true
        if(input["api_mode"] == "rlcm" || input["api_mode"] == "customer" )  
          projects = false
        end # api_mode_if.end               


        if input["api_mode"] == "rlcm"
          deploy_endpoint = "#{env_datacenter}/packages/import/#{input["folder_id"]}?restart_recipes=true"
        elsif input["api_mode"] == "project"
          deploy_endpoint = "#{env_datacenter}/project_builds/#{input["id"]}/deploy?environment_type=#{input["env_type"]}" 
        else 
          deploy_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/imports?folder_id=#{input["folder_id"]}&restart_recipes=true"
        end

        # For RLCM API, download package ID and use it for import
        deploy_body = ""
        if projects
          deploy_body = { "description" => input["description"].to_s }
          headers["Content-Type"] = "application/json"
        else
          src_env_headers = call("get_auth_headers", connection, "#{input["workato_src_environment"]}")
          deploy_body = get("/packages/#{input["id"]}/download")
          .headers(src_env_headers).headers("Accept": "*/*")
          .after_error_response(/.*/) do |_code, body, _header, message|
            error("#{message}: #{body}")
          end.response_format_raw.encode('ASCII-8BIT')
          headers["Content-Type"] = "application/octet-stream"
        end

        response = post(deploy_endpoint) 
        .headers(headers)
        .request_body(deploy_body)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end

        {status: response["status"],
          job_id: response["id"] 
        } 


      end, # execute.end

      output_fields: lambda do |connection|
        [ 
          { name: "status" },
          { name: "job_id" },
        ]
      end
    }, # deploy_package_async.end    
    deploy_package_no_download_async: {
      title: "Deploy package (Asynchronous) with Package as Input",
      subtitle: "Deploy package to Workato environment using package, returns job id",

      help: "Use this action import a package to the selected environment. This is an asynchronous request and will return job id. Learn more <a href=\"https://docs.workato.com/workato-api/recipe-lifecycle-management.html#import-package-into-a-folder\" target=\"_blank\">here</a>.",

      description: lambda do |input| 
        "Deploy <span class='provider'>package</span> to " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span> Asynchronously with package"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        mode = config_fields['api_mode']       
        [
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },          
          {
            name: "deploy_body",
            label: "Package Content",
            hint: "Package downloaded from API.",
            optional: false
          }, 
          { 
            name: "workato_src_environment",
            label: "Source environment",
            hint: "Select Workato DEV environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            toggle_hint: "Custom Value",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_src_environment",
              label: "Workato Source environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },   
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.api_mode == 'customer'",
            optional: true
          },             
          { 
            name: "workato_environment",
            label: "Target environment",
            hint: "Select target Workato environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          {
            name: "folder_id",
            label: "Folder ID",
            hint: "Target environment folder ID to import package into.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true
          },                      
          {
            name: "env_type",
            label: "Environment type",
            hint: "Target environment type. Projects API currently supports only test and prod values.",
            control_type: "select",
            pick_list: "env_type",
            ngIf: "input.api_mode == 'projects'",            
            optional: true
          },
          {
            name: "description",
            label: "Description",
            hint: "Deployment description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }                                                 
        ]
      end,

      execute: lambda do |connection, input, eis, eos, continue|

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        projects = true
        if(input["api_mode"] == "rlcm" || input["api_mode"] == "customer" )  
          projects = false
        end # api_mode_if.end               


        if input["api_mode"] == "rlcm"
          deploy_endpoint = "#{env_datacenter}/packages/import/#{input["folder_id"]}?restart_recipes=true"
        elsif input["api_mode"] == "project"
          deploy_endpoint = "#{env_datacenter}/project_builds/#{input["id"]}/deploy?environment_type=#{input["env_type"]}" 
        else 
          deploy_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/imports?folder_id=#{input["folder_id"]}&restart_recipes=true"
        end

        headers["Content-Type"] = "application/octet-stream"
        response = post(deploy_endpoint) 
        .headers(headers)
        .request_body(input["deploy_body"])
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end

        {status: response["status"],
          job_id: response["id"] 
        } 


      end, # execute.end

      output_fields: lambda do |connection|
        [ 
          { name: "status" },
          { name: "job_id" },
        ]
      end
    }, # deploy_package_no_download_async.end    
    deploy_package_status: {
      title: "Get Deployment Status",
      subtitle: "Get Deployment Status to Workato environment, returns status",

      help: "Use this action get status of a package deployment to the selected environment. Learn more <a href=\"https://docs.workato.com/workato-api/recipe-lifecycle-management.html#import-package-into-a-folder\" target=\"_blank\">here</a>.",

      description: lambda do |input| 
        "Get Deployment Status <span class='provider'>package</span> from " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        mode = config_fields['api_mode']       
        [
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },          
          {
            name: "job_id",
            label: "Job ID",
            hint: "Job ID used for deployment deploy.",
            optional: false
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.api_mode == 'customer'",
            optional: true
          },             
          { 
            name: "workato_environment",
            label: "Target environment",
            hint: "Select target Workato environment.",
            ngIf: "input.api_mode == 'rlcm' || input.api_mode == 'customer'",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },             
          {
            name: "env_type",
            label: "Environment type",
            hint: "Target environment type. Projects API currently supports only test and prod values.",
            control_type: "select",
            pick_list: "env_type",
            ngIf: "input.api_mode == 'projects'",            
            optional: true
          }                                                
        ]
      end,

      execute: lambda do |connection, input, eis, eos, continue|

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")     
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        status_endpoint = ""
        if input["api_mode"] == "rlcm"
          status_endpoint = "#{env_datacenter}/packages/#{input["job_id"]}"
        elsif input["api_mode"] == "project"
          status_endpoint = "#{env_datacenter}/deployments/#{input["job_id"]}"
        else 
          status_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/imports/#{input["job_id"]}"
        end

        response = get(status_endpoint)
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end

        {
          status: response["status"],
          job_id: response["id"],
          error: response["error"] 
        } 


      end, # execute.end

      output_fields: lambda do |connection|
        [ 
          { name: "status" },
          { name: "job_id" },
          { name: "error" },
        ]
      end
    }, # deploy_package_status.end
    list_folders: {
      title: "List all folders",
      subtitle: "List all folders in Workato environment",

      help: "Use this action list folders in the selected environment. Supports up to 100 folders lookup in single action. Repeat this action in recipe for pagination if more than 100 folders lookup is needed.",

      description: lambda do |input| 
        "List <span class='provider'>folders</span> in " \
          "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },      
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },  
          { 
            name: "parent_id",
            label: "Parent Folder Id",
            hint: "Provide folder id",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|

        
        workspace = input["workspace"]
        parent_id = input["parent_id"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/folders" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/folders"
        #api_endpoint = parent_id.present? ? api_endpoint + "&parent_id=" + parent_id : api_endpoint

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        #result_array_name = workspace == "own" ? 'items' : 'result'
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          if parent_id.present? 
            param_input = { parent_id: parent_id, page: page_number, per_page: page_size }.compact
          else
            param_input = { page: page_number, per_page: page_size }.compact
          end

          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          if workspace == "own"
            results = response || []
          else
            results = response['result'] || []
          end
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "result",
            control_type: "key_value",
            type: "array",
            of: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "parent_id" },
              { name: "created_at" },
              { name: "updated_at" }            
            ]
          }
        ]
      end # output_fields.end      

    }, # list_folders.end    
    create_folder: {
      title: "Create folder",
      subtitle: "Create folder in Workato environment",

      help: "Use this action to create folder in the selected environment",

      description: lambda do |input| 
        "Create <span class='provider'>folder</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },                
          {
            name: "folder_name",
            hint: "Name of folder to be created",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
    
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/folders" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/folders"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { folders_list: post(api_endpoint, name: input["folder_name"])
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "folders_list",
            label: "Folders list",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "parent_id" },
              { name: "created_at" },
              { name: "updated_at" }            
            ]
          }
        ]

      end # output_fields.end      

    }, # create_folder.end     
    create_manifest: {
      title: "Create manifest",
      subtitle: "Create manifest in Workato environment",

      help: "Use this action to create manifest in the selected environment",

      description: lambda do |input| 
        "Create <span class='provider'>Manifest</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },   
           {
            name: "export_manifest",
            label: "export_manifest",
            type: "object",
            optional: false,
            properties: [
             { name: "name" },
             { name: "folder_id", type: "integer" , control_type: "integer", convert_input: "integer_conversion" },
             {
              name: "assets",
              label: "assets",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "integer" , control_type: "integer", convert_input: "integer_conversion" },
                { name: "name" },
                { name: "type" },
                { name: "absolute_path" },
                { name: "version", type: "integer", control_type: "integer", convert_input: "integer_conversion" }

              ]
            }]
          }
          
          
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
    
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint =  "#{env_datacenter}/export_manifests"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { folders_list: post(api_endpoint, export_manifest: input["export_manifest"])
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "project_path" },
              { name: "status" }            
            ]
          }
        ]

      end # output_fields.end      

    }, # create_manifest.end       
    list_connections: {
      title: "List connections",
      subtitle: "List connections in Workato environment",

      help: "Use this action to list connections in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>connections</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
      
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/connections" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/connections"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { connections_list: get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
          .after_response do |code, body, headers|
            connections_list = {}
            if workspace != "own"
              connections_list = body
            else
              connections_list["result"] = body
            end
            connections_list
          end}

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "connections_list",
            label: "connections_list",
            control_type: "key_value",
            type: "object",
            properties: [{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "application" },
                { name: "authorized_at", type: "timestamp" },
                { name: "authorization_status" },
                { name: "authorization_error" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "external_id" },
                { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                { name: "identity" },
                { name: "parent_id", type: "number", convert_output: "integer_conversion" }
              ]
            }]
          }
        ]

      end # output_fields.end      

    }, # list_connections.end     
    list_recipes: {
      title: "List recipes",
      subtitle: "List recipes in Workato environment",

      help: "Use this action to list recipes in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>recipes</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },
          { 
            name: "folder_id",
            label: "Folder Id",
            hint: "Provide folder id",
            optional: true
          },    
          {
            name: "page",
            hint: "Used for pagination.",
            type: "integer",
            default: 1
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        folder_id = input["folder_id"]
     
        page = input["page"] || 1
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/recipes?page=#{page}&per_page=100" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/recipes?page=#{page}&per_page=100"

        api_endpoint = folder_id.present? ? api_endpoint + "&folder_id=" + folder_id : api_endpoint
        
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { recipes_list: get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "recipes_list",
            label: "recipes_list",
            control_type: "key_value",
            type: "object",
            properties: [{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "user_id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "copy_count", type: "number", convert_output: "integer_conversion" },
                { name: "trigger_application" },
                { name: "action_applications", type: "array", of: "string" },
                { name: "applications", type: "array", of: "string" },
                { name: "description" },
                { name: "parameters_schema", type: "array" },
                { name: "parameters", type: "object" },
                { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                { name: "running", type: "boolean", convert_output: "boolean_conversion" },
                { name: "job_succeeded_count", type: "number", convert_output: "integer_conversion" },
                { name: "job_failed_count", type: "number", convert_output: "integer_conversion" },
                { name: "lifetime_task_count", type: "number", convert_output: "integer_conversion" },
                { name: "last_run_at", type: "timestamp" },
                { name: "stopped_at", type: "timestamp" },
                { name: "version_no", type: "number", convert_output: "integer_conversion" },
                { name: "webhook_url" },
                { name: "stop_cause" },
                { name: "config", type: "array", of: "object", properties: [ { name: "keyword" }, { name: "name" }, { name: "provider" }, { name: "account_id" } ] },
                { name: "code" }
              ]
            },
               {
                 name: "items",
                 label: "items",
                 control_type: "key_value",
                 type: "array",
                 properties: [
                   { name: "id", type: "number", convert_output: "integer_conversion" },
                   { name: "user_id", type: "number", convert_output: "integer_conversion" },
                   { name: "name" },
                   { name: "created_at", type: "timestamp" },
                   { name: "updated_at", type: "timestamp" },
                   { name: "copy_count", type: "number", convert_output: "integer_conversion" },
                   { name: "trigger_application" },
                   { name: "action_applications", type: "array", of: "string" },
                   { name: "applications", type: "array", of: "string" },
                   { name: "description" },
                   { name: "parameters_schema", type: "array" },
                   { name: "parameters", type: "object" },
                   { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                   { name: "running", type: "boolean", convert_output: "boolean_conversion" },
                   { name: "job_succeeded_count", type: "number", convert_output: "integer_conversion" },
                   { name: "job_failed_count", type: "number", convert_output: "integer_conversion" },
                   { name: "lifetime_task_count", type: "number", convert_output: "integer_conversion" },
                   { name: "last_run_at", type: "timestamp" },
                   { name: "stopped_at", type: "timestamp" },
                   { name: "version_no", type: "number", convert_output: "integer_conversion" },
                   { name: "webhook_url" },
                   { name: "stop_cause" },
                   { name: "config", type: "array", of: "object", properties: [ { name: "keyword" }, { name: "name" }, { name: "provider" }, { name: "account_id" } ] },
                   { name: "code" }
                 ]
               }
            ]
          }
        ]

      end # output_fields.end      

    }, # list_recipes.end     
    list_all_recipes: {
      title: "List all recipes in Workspace",
      subtitle: "List all recipes in selected Workato environment",

      help: "Use this action to list all recipes in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>recipes</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },
          { 
            name: "folder_id",
            label: "Folder Id",
            hint: "Provide folder id",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        folder_id = input["folder_id"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/recipes" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/recipes"
        #api_endpoint = folder_id.present? ? api_endpoint + "&folder_id=" + folder_id : api_endpoint

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        result_array_name = workspace == "own" ? 'items' : 'result'
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          if folder_id.present?
            param_input = { folder_id: folder_id, page: page_number, per_page: page_size }.compact
          else
            param_input = { page: page_number, per_page: page_size }.compact
          end
          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          results = response[result_array_name] || []
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "user_id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "copy_count", type: "number", convert_output: "integer_conversion" },
                { name: "trigger_application" },
                { name: "action_applications", type: "array", of: "string" },
                { name: "applications", type: "array", of: "string" },
                { name: "description" },
                { name: "parameters_schema", type: "array" },
                { name: "parameters", type: "object" },
                { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                { name: "running", type: "boolean", convert_output: "boolean_conversion" },
                { name: "job_succeeded_count", type: "number", convert_output: "integer_conversion" },
                { name: "job_failed_count", type: "number", convert_output: "integer_conversion" },
                { name: "lifetime_task_count", type: "number", convert_output: "integer_conversion" },
                { name: "last_run_at", type: "timestamp" },
                { name: "stopped_at", type: "timestamp" },
                { name: "version_no", type: "number", convert_output: "integer_conversion" },
                { name: "webhook_url" },
                { name: "stop_cause" },
                { name: "config", type: "array", of: "object", properties: [ { name: "keyword" }, { name: "name" }, { name: "provider" }, { name: "account_id" } ] },
                { name: "code" }
              ]
            }
        ]

      end # output_fields.end      

    }, # list_all_recipes.end     
    get_workspace_details: {
      title: "Get Workspace Details",
      subtitle: "Get Workspace Details",

      help: "Use this action to Get Details for the selected Workspace",

      description: lambda do |input| 
        "Get <span class='provider'>Workspace</span> Details from Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },
          { 
            name: "applicationList",
            label: "Application List",
            optional: true
          },
          { 
            name: "outputData",
            label: "Output Data",
            optional: true
          }          
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/recipes" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/recipes"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        result_array_name = workspace == "own" ? 'items' : 'result'
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page

          param_input = { page: page_number, per_page: page_size }.compact

          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          results = response[result_array_name] || []
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        
        
        
         input_stats = records
         application_list = input['applicationList'].split(",")
    

         stats_application = []
         input_stats.each do |ial|
  	        if application_list.include?(ial['trigger_application'])
  		      stats_application << {id: ial['id'], name: ial['name'], running: ial['running'], user_id: ial['user_id'], created_at: ial['created_at'], updated_at: ial['updated_at'], job_succeeded_count: ial['job_succeeded_count'], job_failed_count: ial['job_failed_count'], application: ial['trigger_application'], application_type: "trigger", lifetime_task_count: ial['lifetime_task_count']}
            end
  	        ial['action_applications'].each do |aal|
   		       if application_list.include?(aal)
  			      stats_application << {id: ial['id'], name: ial['name'], running: ial['running'], user_id: ial['user_id'], created_at: ial['created_at'], updated_at: ial['updated_at'], job_succeeded_count: ial['job_succeeded_count'], job_failed_count: ial['job_failed_count'], application: aal, application_type: "action", lifetime_task_count: ial['lifetime_task_count']}
    	       end
	         end

          end

        
        connection_api_endpoint = workspace == "own" ? "#{env_datacenter}/connections" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/connections"

        connections_list = get(connection_api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
          .after_response do |code, body, headers|
            connections_list = {}
            if workspace != "own"
              connections_list = body
            else
              connections_list["result"] = body
            end
            connections_list
          end
        
        { recipes: records, connections_list: connections_list["result"], application_stats: stats_application }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
              name: "recipes",
              label: "recipes",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "user_id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "copy_count", type: "number", convert_output: "integer_conversion" },
                { name: "trigger_application" },
                { name: "action_applications", type: "array", of: "string" },
                { name: "applications", type: "array", of: "string" },
                { name: "description" },
                { name: "parameters_schema", type: "array" },
                { name: "parameters", type: "object" },
                { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                { name: "running", type: "boolean", convert_output: "boolean_conversion" },
                { name: "job_succeeded_count", type: "number", convert_output: "integer_conversion" },
                { name: "job_failed_count", type: "number", convert_output: "integer_conversion" },
                { name: "lifetime_task_count", type: "number", convert_output: "integer_conversion" },
                { name: "last_run_at", type: "timestamp" },
                { name: "stopped_at", type: "timestamp" },
                { name: "version_no", type: "number", convert_output: "integer_conversion" },
                { name: "webhook_url" },
                { name: "stop_cause" },
                { name: "config", type: "array", of: "object", properties: [ { name: "keyword" }, { name: "name" }, { name: "provider" }, { name: "account_id" } ] },
                { name: "code" }
              ]
            },
          {
              name: "connections_list",
              label: "connections_list",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "application" },
                { name: "authorized_at", type: "timestamp" },
                { name: "authorization_status" },
                { name: "authorization_error" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "external_id" },
                { name: "folder_id", type: "number", convert_output: "integer_conversion" },
                { name: "identity" },
                { name: "parent_id", type: "number", convert_output: "integer_conversion" }
              ]
            
          },
           {
    "name": "application_stats",
    "type": "array",
    "of": "object",
    "label": "application_stats",
    "optional": false,
    "properties": [
      {
        "control_type": "text",
        "label": "ID",
        "name": "id",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "Name",
        "name": "name",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "Running",
        "name": "running",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "User ID",
        "name": "user_id",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "Code",
        "name": "code",
        "type": "string",
        "optional": true
      },
      {
        "control_type": "text",
        "label": "Created at",
        "name": "created_at",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "Updated at",
        "name": "updated_at",
        "type": "string"
      },
      {
        "control_type": "text",
        "label": "Job succeeded count",
        "name": "job_succeeded_count",
        "type": "string",
        "optional": false
      },
      {
        "control_type": "text",
        "label": "Job failed count",
        "name": "job_failed_count",
        "type": "string",
        "optional": false
      },
      {
        "control_type": "text",
        "label": "Lifetime task count",
        "name": "lifetime_task_count",
        "type": "string",
        "optional": false
      },
      {
        "control_type": "text",
        "label": "Application",
        "name": "application",
        "type": "string",
        "optional": true
      },
      {
        "control_type": "text",
        "label": "Application type",
        "name": "application_type",
        "type": "string",
        "optional": false
      }
    ]
  }
        ]

      end # output_fields.end      

    }, # list_all_recipes.end         
    create_customer: {
      title: "Create customer",
      subtitle: "Create customer from Workato Embedded Admin Account",

      help: "Use this action to create workspace from selected Admin Account",

      description: lambda do |input| 
        "Create <span class='provider'>Workspace</span> from selected Admin Account"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },       
          {
            name: "workspace_name",
            hint: "Name of Workspace to be created",
            type: :string,
            optional: false,
            control_type: "text"
          },       
          {
            name: "workspace_email",
            hint: "Email Id for Workspace notifications",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "external_id",
            hint: "External ID",
            type: :string,
            optional: true,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        api_endpoint = "#{env_datacenter}/managed_users"
        inputjson = ''
        if input["external_id"].present?
          inputjson = {name: input["workspace_name"], notification_email: input["workspace_email"], external_id: input["external_id"]}
        else
          inputjson = {name: input["workspace_name"], notification_email: input["workspace_email"]}
        end

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { folders_list: post(api_endpoint, inputjson)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "folders_list",
            label: "Folders list",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "external_id" },
              { name: "created_at" },
              { name: "updated_at" }            
            ]
          }
        ]

      end # output_fields.end      

    }, # create_customer.end     
    update_properties: {
      title: "Update Account Properties",
      subtitle: "Update Account Properties in the selected environment",

      help: "Use this action to update account properties in the selected environment",

      description: lambda do |input| 
        "Update <span class='provider'>Workspace</span> Acount Properties"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },    
          { 
            name: "project_id",
            label: "Project Id",
            hint: "Provide project id",
            optional: true
          },   
          {
            name: "property_name",
            hint: "Property Name",
            type: :string,
            optional: false,
            control_type: "text"
          },       
          {
            name: "property_value",
            hint: "Property Value",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/properties" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/properties"
        if input["project_id"].present?
          api_endpoint = api_endpoint + "?project_id=" + input["project_id"]
        end
        property_name = input["property_name"]
        property_value = input["property_value"]

        property_string = '{ "properties" :{"'+ property_name +'": "'+property_value+'"}}'

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: post(api_endpoint, parse_json(property_string))
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "success" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # update_properties.end     
    update_connection: {
      title: "Update Connection",
      subtitle: "Update Connection from Workato Embedded Admin Account",

      help: "Use this action to update Connection from Workato Embedded Admin Account",

      description: lambda do |input| 
        "Update <span class='provider'>Workspace</span> Connection"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },     
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            optional: false
          },            
          {
            name: "connection_id",
            hint: "Connection Id",
            type: :string,
            optional: false,
            control_type: "text"
          },       
          {
            name: "connection_name",
            hint: "Connection Name",
            type: :string,
            optional: true,
            control_type: "text"
          },
          {
            name: "provider",
            hint: "Provider",
            type: :string,
            optional: true,
            control_type: "text"
          },
          {
            name: "folder_id",
            hint: "Folder Id",
            type: :string,
            optional: true,
            control_type: "text"
          },
          {
            name: "append_string",
            hint: "Append String",
            type: :string,
            optional: true,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        api_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/connections/#{input["connection_id"]}"
        folder_id = input["folder_id"]
        connection_name = input["connection_name"]
        append_string = input["append_string"]
        provider = input["provider"]
        if append_string.present? 
          if connection_name.present?
            http_body_string = '{"name": "'+connection_name+'", "provider":"'+provider +'", "folder_id":"'+folder_id +'", '+append_string +'}'
          else
            http_body_string = '{'+ append_string +'}'
          end
        else
          if connection_name.present?
            http_body_string = '{"name": "'+connection_name+'", "provider":"'+provider +'", "folder_id":"'+folder_id +'"}'
          else
            http_body_string = '{}'
          end
        end
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: put(api_endpoint, parse_json(http_body_string))
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "authorization_status" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # update_connection.end     
    create_connection: {
      title: "Create Connection",
      subtitle: "Create Connection from Workato Embedded Admin Account",

      help: "Use this action to create Connection from Workato Embedded Admin Account",

      description: lambda do |input| 
        "Create <span class='provider'>Workspace</span> Connection"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },     
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            optional: false
          },               
          {
            name: "connection_name",
            hint: "Connection Name",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "provider",
            hint: "Provider",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "folder_id",
            hint: "Folder Id",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "append_string",
            hint: "Append String",
            type: :string,
            optional: true,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        api_endpoint = "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/connections"
        folder_id = input["folder_id"]
        connection_name = input["connection_name"]
        append_string = input["append_string"]
        provider = input["provider"]
        if append_string.present?
          http_body_string = '{"name": "'+connection_name+'", "provider":"'+provider +'", "folder_id":"'+folder_id +'", '+append_string +'}'
        elsif
          http_body_string = '{"name": "'+connection_name+'", "provider":"'+provider +'", "folder_id":"'+folder_id +'"}'
        end
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: post(api_endpoint, parse_json(http_body_string))
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "authorization_status" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # create_connection.end     
    start_recipe: {
      title: "Start Recipe",
      subtitle: "Start Recipe in the selected environment",

      help: "Use this action to Start Recipe in the selected environment",

      description: lambda do |input| 
        "Start Recipe <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "recipe_id",
            hint: "Recipe Id",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
    
        api_endpoint = workspace == "own" ? "#{env_datacenter}/recipes/#{input["recipe_id"]}/start" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/recipes/#{input["recipe_id"]}/start"


        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: put(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "success" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # start_recipe.end     
    stop_recipe: {
      title: "Stop Recipe",
      subtitle: "Stop Recipe in the selected environment",

      help: "Use this action to Stop Recipe in the selected environment",

      description: lambda do |input| 
        "Stop Recipe <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "recipe_id",
            hint: "Recipe Id",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/recipes/#{input["recipe_id"]}/start" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/recipes/#{input["recipe_id"]}/stop"


        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: put(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "success" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # stop_recipe.end     
    get_customers: {
      title: "Get customers",
      subtitle: "Get customers from Workato Embedded Admin Account",

      help: "Use this action to get customer workspaces from selected Admin Account",

      description: lambda do |input| 
        "Get Customers<span class='provider'>Workspace</span> from selected Admin Account"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          {
            name: "page",
            hint: "Used for pagination.",
            type: "integer",
            optional: false,
            default: 1
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workato_environment"]
        page = input["page"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        api_endpoint = "#{env_datacenter}/managed_users?page=#{page}"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { customer_list: get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "customer_list",
            label: "Customers list",
            control_type: "key_value",
            type: "object",
            properties: [{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              properties: [
                { name: "id" },
                { name: "name" },            
                { name: "user_id" },
                { name: "created_at" },
                { name: "updated_at" }     

              ]
            }]
          }
        ]


      end # output_fields.end      

    }, # get_customers.end  
    list_customer_accounts: {
      title: 'List customer accounts',
      subtitle: 'List customer accounts in Workato Embedded',
      description: "List <span class='provider'>Customer accounts</span> " \
        "in <span class='provider'>Workato Embedded</span>",

      help: lambda do |_input|
        <<~HELP
          This action will return a list of entries according to the
          provided page number. Otherwise, it will paginate and
          return all records. <br>
          <br>To perform this action, the <b>List</b>
          permission is required.<br><br>
          You may enable it by navigating to the left sidebar > click
          <b>Workspace access</b> > go to <b>API clients</b> tab >
          <b>Client roles</b> > <a href='https://docs.workato.com/
          workato-api/api-clients.html#updating-an-api-client-or-
          client-role' target='_blank'>Select your desired role or
          create a new one</a> > under <b>CUSTOMER WORKSPACES</b> section,
          click <b>Admin</b> > scroll down through the <b>Customer workspaces</b>
          section > expand the <b>Customer workspaces</b> option by clicking
          the arrow > check <b>List</b> when API client
          authentication is used.<br><br>
          <a href='https://docs.workato.com/oem/oem-api/managed-users.html#
          get-list-of-customer-accounts' target='_blank'>Learn more </a>
        HELP
      end,

      input_fields: lambda do |object_definitions|
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          }
        ]      
      end,
      execute: lambda do |connection, input|
        workspace = input["workato_environment"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = "#{env_datacenter}/managed_users"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        max_page_size = 100
        page_size = input['per_page'] || max_page_size
        page_size = page_size > max_page_size ? max_page_size : page_size
        page_number = input['page']
        only_ask_for_one_page = page_number.present?
        page_number = page_number || 1
        ask_for_next_page = true
        records = []

        while ask_for_next_page
          param_input = { page: page_number, per_page: page_size }.compact
          response = get(api_endpoint, param_input).headers(headers).
                     after_error_response(/.*/) do |code, body, _header, message|
                       if connection['auth_type'] == 'api_token' && code.to_s == '401'
                         error('401 Unauthorized: Missing permission. You may enable'\
                               ' it by navigating to the left sidebar > click Workspace '\
                               'access > go to API clients tab > Client roles > Select '\
                               'your desired role or create a new one > under CUSTOMER '\
                               'WORKSPACES section, click Admin > scroll down through'\
                               ' the Customer workspaces section > expand the Customer'\
                               ' workspaces option by clicking the arrow > check List '\
                               'when API client authentication is used.')
                       else
                         error("#{message}: #{body}")
                       end
                     end
          results = response['result'] || []
          if only_ask_for_one_page
            ask_for_next_page = false
          else
            page_number = page_number + 1
            error('Unexpected page size') if results.length > max_page_size
            ask_for_next_page = results.length == page_size
          end
          records.concat(results)
        end

        { result: records }
      end,

      output_fields: lambda do |object_definitions|
        object_definitions['list_customer_accounts_output']
      end,

      sample_output: lambda do |_connection, _input|
        get('/api/managed_users')
      end
    },
    get_usage: {
      title: "Get usage for customers",
      subtitle: "Get usage for customers",

      help: "Use this action to get usage for customers workspace from selected Admin Account",

      description: lambda do |input| 
        "Get Usage<span class='provider'>Workspace</span> from selected Admin Account"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workato_environment"]
        page = input["page"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])

        api_endpoint = "#{env_datacenter}/managed_users/usage"

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { usage: get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "usage",
            label: "Usage",
            control_type: "key_value",
            type: "object",
            properties: [{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "object",
              properties: [{
                name: "data",
                label: "data",
                control_type: "key_value",
                type: "array",
                properties: [          
                  { name: "user_id" },
                  { name: "intervals",
                    label: "intervals",
                    control_type: "key_value",
                    type: "array",
                    properties: [    
                      { name: "start_datetime" },
                      { name: "task_count",
                        type: "integer"}     
                    ]
                  }]
                }]
              }]
            }
        ]
          
        


      end # output_fields.end      

    }, # get_usage.end   
    get_environment_details: {
      title: "Get environment details",
      subtitle: "Get environment/workspace details configured in this connection",

      help: "Use this action to get environment details configured in this connection",

      description: lambda do |input| 
        "Get Environments"
      end,

      input_fields: lambda do |object_definitions|
        [
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          }
        ]      
      end,

      execute: lambda do |connection, input, eis, eos, continue|
        name = connection['workato_environments'].where(name: input["workato_environment"]).pluck("name").first()
        data_center = connection['workato_environments'].where(name: input["workato_environment"]).pluck("data_center").first()
        data_center_url = data_center.gsub("/api","/")
       
        {name: name, data_center_url: data_center_url}
      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          { name: "name" },
          { name: "data_center_url" }
        ]


      end # output_fields.end      

    }, # get_environment_details.end        
    get_environments: {
      title: "Get environments",
      subtitle: "Get environments/workspaces configured in this connection",

      help: "Use this action to get environments/workspaces configured in this connection",

      description: lambda do |input| 
        "Get Environments"
      end,


      execute: lambda do |connection, input, eis, eos, continue|
        {environment_list: connection['workato_environments'].pluck("name")}
      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {name: "name"},
          {name: "data_center"}
        ]


      end # output_fields.end      

    }, # get_environments.end     
    create_api_client: {
      title: "Create API Client",
      subtitle: "Create API Client in the selected environment",

      help: "Use this action to create API Client in the selected environment",

      description: lambda do |input| 
        "Create API Client in <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "client_name",
            hint: "API Client Name",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        client_name = input["client_name"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_clients" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_clients"
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        
        client_list = get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
        
        if client_list.pluck('name').include?(client_name).is_true?
          { result:
              {message: "client name already present"}
          }
        
        else
        
          http_body_string = '{"name": "' + client_name + '"}'

          { 
            result: post(api_endpoint, parse_json(http_body_string))
              .headers(headers)
              .after_error_response(/.*/) do |_, body, _, message|
                error("#{message}: #{body}") 
              end
        }
        end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "message" }         


            ]
          }
        ]

      end # output_fields.end      

    }, # create_api_client.end     
    list_api_clients: {
      title: "List API Clients in Workspace",
      subtitle: "List API Clients in Workato environment",

      help: "Use this action to list API Clients in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>API Clients</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_clients" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_clients"
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          param_input = { page: page_number, per_page: page_size }.compact

          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          results = response || []
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "project_id" }               
              ]
            }
        ]

      end # output_fields.end      

    }, # list_api_clients.end          
    create_api_access_profiles: {
      title: "Create API Access Profile",
      subtitle: "Create API Access Profile in the selected environment",

      help: "Use this action to create API Access Profile in the selected environment",

      description: lambda do |input| 
        "Create API Access Profile in <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "api_client_id",
            hint: "API Client ID",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "access_profile_name",
            hint: "API Access Profile Name",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "api_collection_name",
            hint: "API Collection Name",
            type: :array,
            of: :integer,
            optional: false,
            control_type: "text"
          },
          {
            name: "auth_type",
            hint: "Auth Type",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "ip_allow_list",
            hint: "List of IP addresses to be allowlisted",
            type: :array,
            of: :string,
            optional: true,
            control_type: "text"
          }          
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        api_client_id = input["api_client_id"]
        access_profile_name = input["access_profile_name"]
        api_collection_name = input["api_collection_name"]
        auth_type = input["auth_type"]
        ip_allow_list = input["ip_allow_list"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_access_profiles?api_client_id=" + api_client_id : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_access_profiles?api_client_id=" + api_client_id
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        
        client_list = get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
        
        if client_list.length > 0 && client_list.pluck('name').include?(access_profile_name).is_true?
          { result:
              {message: "Access Profile name already present"}
          }
        
        else
          list_api_endpoint = workspace == "own" ? "#{env_datacenter}/api_collections" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_collections"
          api_collection_ids = []

          api_list = get(list_api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
          
          api_list.each do |api|
            if api_collection_name.include?(api["name"])
              api_collection_ids.concat([api["id"]])
            end
          end
          
          
          http_body_string = '{"name": "'+access_profile_name+'", "api_client_id":"'+api_client_id +'", "api_collection_ids":'+api_collection_ids+', "auth_type":"'+auth_type +'", "ip_allow_list":'+ (ip_allow_list.present? ? ip_allow_list : '[]') +', "active": true}'

          { 
            result: post(api_endpoint, parse_json(http_body_string))
              .headers(headers)
              .after_error_response(/.*/) do |_, body, _, message|
                error("#{message}: #{body}") 
              end
        }
        end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "message" }         


            ]
          }
        ]

      end # output_fields.end      

    }, # create_api_access_profiles.end         
    update_api_access_profiles: {
      title: "Update API Access Profile",
      subtitle: "Update API Access Profile in the selected environment",

      help: "Use this action to update API Access Profile in the selected environment",

      description: lambda do |input| 
        "Update API Access Profile in <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "api_client_id",
            hint: "API Client ID",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "access_profile_id",
            hint: "API Access Profile Id",
            type: :string,
            optional: false,
            control_type: "integer"
          },
          {
            name: "access_profile_name",
            hint: "API Access Profile Name",
            type: :string,
            optional: false,
            control_type: "text"
          },          
          {
            name: "api_collection_name",
            hint: "API Collection Name",
            type: :array,
            of: :integer,
            optional: false,
            control_type: "text"
          },
          {
            name: "auth_type",
            hint: "Auth Type",
            type: :string,
            optional: false,
            control_type: "text"
          },
          {
            name: "ip_allow_list",
            hint: "List of IP addresses to be allowlisted",
            type: :array,
            of: :string,
            optional: true,
            control_type: "text"
          }          
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        api_client_id = input["api_client_id"]
        access_profile_id = input["access_profile_id"]
        access_profile_name = input["access_profile_name"]

        api_collection_name = input["api_collection_name"]
        auth_type = input["auth_type"]
        ip_allow_list = input["ip_allow_list"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_access_profiles/=" + access_profile_id : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_access_profiles/" + access_profile_id
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        
        client_list = get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
        

          list_api_endpoint = workspace == "own" ? "#{env_datacenter}/api_collections" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_collections"
          api_collection_ids = []

          api_list = get(list_api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
          
          api_list.each do |api|
            if api_collection_name.include?(api["name"])
              api_collection_ids.concat([api["id"]])
            end
          end
          
          
          http_body_string = '{"name": "'+access_profile_name+'", "api_client_id":"'+api_client_id +'", "api_collection_ids":'+api_collection_ids+', "auth_type":"'+auth_type +'", "ip_allow_list":'+ (ip_allow_list.present? ? ip_allow_list : '[]') +', "active": true}'

          { 
            result: put(api_endpoint, parse_json(http_body_string))
              .headers(headers)
              .after_error_response(/.*/) do |_, body, _, message|
                error("#{message}: #{body}") 
              end
        }
        

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "message" }         


            ]
          }
        ]

      end # output_fields.end      

    }, # update_api_access_profiles.end             
    list_api_access_profiles: {
      title: "List API Access Profiles in Workspace",
      subtitle: "List API Access Profiles in Workato environment",

      help: "Use this action to list API Aceess Orifiles in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>API Access Profiles</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_access_profiles" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_access_profiles"
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          param_input = { page: page_number, per_page: page_size }.compact

          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          results = response || []
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "name" },
                { name: "api_client_id" },
                { name: "api_collection_ids", type: "array", of: "integer" },
                { name: "active" },
                { name: "auth_type" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" }
               
              ]
            }
        ]

      end # output_fields.end      

    }, # list_api_access_profiles.end         
    list_api_collections: {
      title: "List API Collections in Workspace",
      subtitle: "List API Collections in Workato environment",

      help: "Use this action to list API Collections in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>API Collections</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_collections" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_collections"
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          param_input = { page: page_number, per_page: page_size }.compact

          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          if workspace == "own"
            results = response || []
          else
            results = response["result"] || []
          end
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "version"},
                { name: "name" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
                { name: "project_id", type: "number", convert_output: "integer_conversion" },
                { name: "url" },
                { name: "api_spec_url"},
               
              ]
            }
        ]

      end # output_fields.end      

    }, # list_api_collections.end     
    list_api_endpoints: {
      title: "List API Endpoints in Workspace",
      subtitle: "List API Endpoints in Workato environment",

      help: "Use this action to list API Endpoints in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>API Endpoints</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },
          { 
            name: "api_collection_id",
            label: "API Collection Id",
            hint: "Select customer id",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        api_collection_id = input["api_collection_id"]
        
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_endpoints" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_endpoints"
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        page_number = 1
        ask_for_next_page = true
        page_size = 100
        records = []
        while ask_for_next_page
          if api_collection_id.present? 
            param_input = { api_collection_id: api_collection_id, page: page_number, per_page: page_size }.compact
          else
            param_input = { page: page_number, per_page: page_size }.compact            
            
          end
          response =  get(api_endpoint, param_input)
            .headers(headers)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end 
          if workspace == "own"
            results = response || []
          else
            results = response["result"] || []
          end
          page_number = page_number + 1
          ask_for_next_page = results.length == page_size

          records.concat(results)
         end
        { result: records }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
{
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "api_collection_id", type: "number", convert_output: "integer_conversion" },
                { name: "flow_id", type: "number", convert_output: "integer_conversion"  },
                { name: "name" },
                { name: "method" },
                { name: "url" },
                { name: "legacy_url" },
                { name: "base_path" },
                { name: "path" },
                { name: "active" },
                { name: "legacy" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" },
              ]
            }
        ]

      end # output_fields.end      

    }, # list_api_endpoints.end         
    enable_api_endpoint: {
      title: "Enable API Endpoint",
      subtitle: "Enable API Endpointe in the selected environment",

      help: "Use this action to Enable API Endpoint in the selected environment",

      description: lambda do |input| 
        "Enable API Endpoint in <span class='provider'>Workspace</span> "
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },            
          {
            name: "api_endpoint_id",
            hint: "API Endpoint Id",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
    
        api_endpoint = workspace == "own" ? "#{env_datacenter}/api_endpoints/#{input["api_endpoint_id"]}/enable" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/api_endpoints/#{input["api_endpoint_id"]}/enable"


        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: put(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "success" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # enable_api_endpoint.end        
    run_testcases_async: {
      title: "Run All Test Cases (Asynchronous)",
      subtitle: "Run All Configured Test Cases",
      
      help: "Use this action to Run All Configured Test Cases.",
      
      description: lambda do |input| 
        "Run <span class='provider'>All Test Cases</span> in " \
        "<span class='provider'>Workato</span>"
      end,
      
      input_fields: lambda do |object_definitions| [
        {
          label: "Workato environment",
          type: "string",
          name: "workato_environment",
          control_type: "select",
          toggle_hint: "Select from list",
          pick_list: "environments",
          toggle_field: {
            name: "workato_environment",
            label: "Workato environment",
            type: "string",
            control_type: "text",
            optional: false,
            toggle_hint: "Custom value",
          },             
          optional: false,
          hint: "Select Environment"
        },{
          label: "asset_id",
          type: "string",
          name: "asset_id",
          control_type: "text",
          optional: true,
          hint: "Specify Asset ID whose test cases you want to trigger."
        },{
          label: "asset_type",
          type: "string",
          name: "asset_type",
          control_type: "text",
          optional: true,
          hint: "Specify Asset Type: rlcm, projects, folder, recipe or testcase"
        }]
      end,
      
      execute: lambda do |connection, input, eis, eos, continue|
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        headers['Content-Type'] = 'application/json'
        
        payload = {}
        if input["asset_id"].present?
          payload["manifest_id"] = input["asset_id"].to_i if input["asset_type"] == "rlcm"
          payload["project_id"] = input["asset_id"].to_i if input["asset_type"] == "projects"
          payload["folder_id"] = input["asset_id"].to_i if input["asset_type"] == "folder"
          payload["recipe_id"] = input["asset_id"].to_i if input["asset_type"] == "recipe"
          payload["test_case_ids"] = input["asset_id"] if input["asset_type"] == "testcase"
        end
        
        post("#{env_datacenter}/test_cases/run_requests")
        .headers(headers)
        .payload(payload)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end
      end, # execute.end
      
      output_fields: lambda do |object_definitions| [
        { name: "data", type: "object", properties: [
          { name: "id" },
          { name: "status" },
          { name: "user", type: "object", properties: [{ name: "id" }]},
          { name: "created_at" },
          { name: "updated_at" },
          { name: "results", type: "array", of: "object", properties: [
            { name: "recipe", type: "object", properties: [
              { name: "id" },
              { name: "name" }]},
            { name: "test_case", type: "object", properties: [
              { name: "id" },
              { name: "name" }]},
            { name: "job", type: "object", properties: [{ name: "id" }]},
            { name: "status" }]}]}]
      end # output_fields.end      
    }, # run_test_cases.end
    get_testcase_status: {
      title: "Get Test Case Status",
      subtitle: "Get Status of Running Test Cases",
      
      help: "Use this action to Get the Status of Running Test Cases.",
      
      description: lambda do |input| 
        "Get <span class='provider'>Status of Test Cases</span> in " \
        "<span class='provider'>Workato</span>"
      end,
      
      input_fields: lambda do |object_definitions| [
        {
          label: "Workato environment",
          type: "string",
          name: "workato_environment",
          control_type: "select",
          toggle_hint: "Select from list",
          pick_list: "environments",
          toggle_field: {
            name: "workato_environment",
            label: "Workato environment",
            type: "string",
            control_type: "text",
            optional: false,
            toggle_hint: "Custom value",
          },             
          optional: false,
          hint: "Select Environment"
        },{
          label: "id",
          type: "string",
          name: "id",
          control_type: "text",
          optional: false,
          hint: "Get the status of a specified test case."
        }]
      end,
      
      execute: lambda do |connection, input, eis, eos, continue|
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        testcase_endpoint = "#{env_datacenter}/test_cases/run_requests/"
        
        if input['id'].present?
          testcase_endpoint = testcase_endpoint + input['id']
        end
        
        get(testcase_endpoint)
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end
      end, # execute.end
      
      output_fields: lambda do |object_definitions|[
        { name: "data", type: "object", properties: [
          { name: "id" },
          { name: "status" },
          { name: "user", type: "object", properties: [{ name: "id" }]},
          { name: "created_at" },
          { name: "updated_at" },
          { name: "coverage", type: "object", properties: [
            { name: "value" },
            { name: "total_actions_count" },
            { name: "total_visited_actions_count" },
            { name: "recipes", type: "array", of: "object", properties: [
              { name: "id" },
              { name: "version_no" },
              { name: "coverage", type: "object", properties: [
                { name: "value" },
                { name: "not_visited_actions", type: "array", of: "object", 
                  properties: [{ name: "step_number" }]}]}]}]},
          { name: "results", type: "array", of: "object",
            properties: [{ name: "recipe", type: "object", properties: [
              { name: "id" },
              { name: "name" }]},
              { name: "test_case", type: "object", properties: [
                { name: "id" },
                { name: "name" }]},
              { name: "job", type: "object", properties: [
                { name: "id" }]},
              { name: "status" }]}]}]
      end
    }, # run_test_cases.end
    get_recipe_testcases: {
      title: "Get All Test Cases of a Recipe",
      subtitle: "Get All Configured Test Cases in a Recipe",
      
      help: "Use this action to Get All Configured Test Cases in a Recipe.",
      
      description: lambda do |input| 
        "Get <span class='provider'>All Test Cases</span> for a Recipe in " \
        "<span class='provider'>Workato</span>"
      end,
      
      input_fields: lambda do |object_definitions| [
        {
          label: "Workato environment",
          type: "string",
          name: "workato_environment",
          control_type: "select",
          toggle_hint: "Select from list",
          pick_list: "environments",
          toggle_field: {
            name: "workato_environment",
            label: "Workato environment",
            type: "string",
            control_type: "text",
            optional: false,
            toggle_hint: "Custom value",
          },             
          optional: false,
          hint: "Select Environment"
        },{
          label: "recipe_id",
          type: "integer",
          name: "recipe_id",
          control_type: "text",
          optional: false,
          hint: "Get all test cases for specified recipe."
        }]
      end,
      
      execute: lambda do |connection, input, eis, eos, continue|
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        testcase_endpoint = "#{env_datacenter}/recipes/"
        
        if input['recipe_id'].present?
          testcase_endpoint = testcase_endpoint + input['recipe_id'] + "/test_cases"
        end
        
        get(testcase_endpoint)
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end
      end, # execute.end
      
      output_fields: lambda do |object_definitions|[
        { name: "data", type: "object", properties: [
          { name: "id" },
          { name: "created_at" },
          { name: "updated_at" },
          { name: "description" },
          { name: "name" }]}]
      end
    }, # run_test_cases.end
    list_projects: {
      title: "List Projects",
      subtitle: "List Projects in Workato environment",
      
      help: "Use this action to Lists all Projects in the selected Environment. Projects are top level folders. Supports up to 100 Project lookups in single action. Repeat this action in recipe for pagination if more than 100 Project lookups are needed.",
      
      description: lambda do |input| 
        "List <span class='provider'>Projects</span> in <span class='provider'>Workato</span>"
      end,
      
      input_fields: lambda do |object_definitions| 
        [
          {
            label: "Workato environment",
            type: "string",
            name: "workato_environment",
            control_type: "select",
            toggle_hint: "Select from list",
            pick_list: "environments",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: "string",
              control_type: "text",
              optional: false,
              toggle_hint: "Custom value",
            },             
            optional: false,
            hint: "Select environment."
          },
          {
            name: "page",
            hint: "Used for pagination.",
            type: "integer",
            default: 1
          }
        ]
      end, 
      
      execute: lambda do |connection, input, eis, eos, continue|
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        page = input["page"] || 1
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        folder_endpoint = "#{env_datacenter}/projects?page=#{page}"
        
        { project_list: get(folder_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }
      end, # execute.end
      
      output_fields: lambda do |object_definitions|
        [
          {
            name: "project_list",
            label: "Project List",
            control_type: "key_value",
            type: "array",
            of: "object",
            properties: [
              { name: "id" },
              { name: "description" },
              { name: "folder_id" },
              { name: "name" }
            ]
          }
        ]
      end # output_fields.end      
      
    }, # list_projects.end    
    update_lookup_table_row: {
      title: "Update Lookup Table Row",
      subtitle: "Update Lookup Table Row in the selected environment",

      help: "Use this action to update Lookup Table Row in the selected environment",

      description: lambda do |input| 
        "Update <span class='provider'>Lookup Table</span> Row"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },    
          { 
            name: "lookup_table_id",
            label: "Lookup Table Id",
            hint: "Provide lookup table id",
            optional: true
          },   
          {
            name: "row_id",
            hint: "Row Id",
            type: :string,
            optional: false,
            control_type: "text"
          },       
          {
            name: "value",
            hint: "Value",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/lookup_tables/#{input["lookup_table_id"]}/rows/#{input["row_id"]}" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/lookup_tables/#{input["lookup_table_id"]}/rows/#{input["row_id"]}"

        value = input["value"]

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: post(api_endpoint, parse_json(value))
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # update_lookup_table_row.end     
    add_lookup_table_row: {
      title: "Add Lookup Table Row",
      subtitle: "Add Lookup Table Row in the selected environment",

      help: "Use this action to add Lookup Table Row in the selected environment",

      description: lambda do |input| 
        "Add <span class='provider'>Lookup Table</span> Row"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: true,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              optional: true,
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },    
          { 
            name: "lookup_table_id",
            label: "Lookup Table Id",
            hint: "Provide lookup table id",
            optional: true
          },     
          {
            name: "value",
            hint: "Value",
            type: :string,
            optional: false,
            control_type: "text"
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
      
        api_endpoint = workspace == "own" ? "#{env_datacenter}/lookup_tables/#{input["lookup_table_id"]}/rows" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/lookup_tables/#{input["lookup_table_id"]}/rows"

        value = input["value"]

        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { result: post(api_endpoint, parse_json(value))
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end }

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
          {
            name: "result",
            label: "Result",
            control_type: "key_value",
            type: "object",
            properties: [
              { name: "id" }         
            ]
          }
        ]

      end # output_fields.end      

    }, # add_lookup_table_row.end          
    query_lookup_table_row: {
      title: "Query Lookup Table Row",
      subtitle: "Query lookup table row in Workato environment",

      help: "Use this action to Query Lookup Table Row in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>Query Lookup Table Row</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          },
          { 
            name: "lookup_table_id",
            label: "Lookup Table Id",
            hint: "Lookup Table id",
            optional: false
          },    
          {
            name: "by",
            label: "By",
            hint: "Seach condition",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        lookup_table_id = input["lookup_table_id"]
     
        page = input["page"] || 1
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/lookup_tables/#{input["lookup_table_id"]}/rows" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/lookup_tables/#{input["lookup_table_id"]}/rows"

        if query_param = input["by"].present?
          api_endpoint = api_endpoint + "?by"+ input["by"]
        end
        
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        result = get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
        if workspace == "own"
          rows = result
        else
          rows = result["result"]
        end
        {rows: rows}

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
           {
              name: "rows",
              label: "rows",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" }
              ]
            }
            
        ]

      end # output_fields.end      

    }, # query_lookup_table_row.end         
    list_lookup_tables: {
      title: "List Lookup Tables",
      subtitle: "List lookup tables in Workato environment",

      help: "Use this action to List Lookup Tables in the selected environment",

      description: lambda do |input| 
        "List <span class='provider'>Lookup Tables</span> in Workato"
      end,

      input_fields: lambda do |object_definitions| 
        [
          { 
            name: "workspace",
            label: "Workspace",
            hint: "Select workspace",
            optional: false,
            control_type: "select",
            pick_list: "workspace",

          },  
          { 
            name: "workato_environment",
            label: "Workato environment",
            hint: "Select Workato environment.",
            optional: false,
            control_type: "select",
            pick_list: "environments",
            toggle_hint: "Select from list",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: :string,
              control_type: "text",
              toggle_hint: "Custom Value",
              hint: "Map DEV, TEST or PROD"
            }
          },
          { 
            name: "workato_customer_user_id",
            label: "Customer Id",
            hint: "Select customer id",
            ngIf: "input.workspace == 'customer'",
            optional: true
          }
        ]
      end, 

      execute: lambda do |connection, input, eis, eos, continue|
        workspace = input["workspace"]
        lookup_table_id = input["lookup_table_id"]
     
        env_datacenter = call("get_environment_datacenter", connection, input["workato_environment"])
        api_endpoint = workspace == "own" ? "#{env_datacenter}/lookup_tables" : "#{env_datacenter}/managed_users/#{input["workato_customer_user_id"]}/lookup_tables"

        result = []
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        rows = get(api_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 
        if workspace == "own"
          result = rows
        else
          result = rows["result"]
        end
        
        {result: result}

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [
           {
              name: "result",
              label: "result",
              control_type: "key_value",
              type: "array",
              of: "object",
              properties: [
                { name: "id", type: "number", convert_output: "integer_conversion" },
                { name: "name"},
                { name: "created_at", type: "timestamp" },
                { name: "updated_at", type: "timestamp" }
              ]
            }
            
        ]

      end # output_fields.end      

    }, # list_lookup_tables.end          
  },

  methods: {
    get_auth_headers: lambda do |connection, env|
      auth_obj = connection["workato_environments"].select { |e| e["name"].upcase == ("#{env}".upcase) }
      result = {}
      if auth_obj[0]["email"].present?
        result = {
          "x-user-email": "#{auth_obj[0]["email"]}",
          "x-user-token": "#{auth_obj[0]["api_key"]}"
        }
      elsif
        result = {
          "Authorization": "Bearer #{auth_obj[0]["api_key"]}"
        }
      end

      result
    end, # get_auth_headers.end

    download_from_url: lambda do |input|
      input["headers"][:Accept] = "*/*"
      { 
        workato_environment: input["workato_environment"],
        package_id: input["package_id"],
        api_mode: input["api_mode"],
        content: get(input["download_url"])
        .headers('Accept' => '*/*')
        .after_error_response(/.*/) do |_code, body, _header, message|
          error("#{message}: #{body}")
        end.response_format_raw
      }   
    end, # download_from_url.end
    # Get environment data center
    get_environment_datacenter: lambda do |connection, environment|
      env_data_center = ""
      #env_detail = connection['workato_environments'].where(name: environment.upcase).first
      env_detail =  connection["workato_environments"].select { |e| e["name"].upcase == ("#{environment}".upcase) }.first
      if env_detail.present?
        env_data_center = env_detail['data_center']
      end
      env_data_center
    end, # get_environment_datacenter.end
    customer_accounts_input_schema: lambda do
      [
        { name: 'id', label: 'Account ID/External ID',
          hint: 'Workato embedded customer account ID or external ID.
          The external ID must be prefixed with an E. e.g. EA2300' },
        { name: 'name',
          hint: 'Full name of the user. e.g. John Doe', sticky: true },
        { name: 'external_id', sticky: true,
          hint: 'External identifier for the Workato Embedded customer.' },
        { name: 'notification_email',
          hint: 'Email for error notifications.' },
        { name: 'error_notification_emails',
          hint: 'Emails for error notifications. This property'\
          ' overrides what you input in notification email property.' },
        { name: 'admin_notification_emails',
          hint: 'Emails for administrative notifications. This property'\
          ' overrides what you input in notification email property.' },
        { name: 'plan_id', sticky: true,
          hint: 'Default Plan ID is used when not provided' },
        { name: 'origin_url', label: 'Origin URL',
          hint: 'Applies to embedded OEM account customers.
          Provide a value if the embedded IFrame is hosted in a
          non-default origin page (e.g. customer-specific custom domains,
          etc.). Defaults to the origin configured at the account level.' },
        { name: 'whitelisted_apps', type: 'array', of: 'string',
          hint: "A list of connection
          <a href='https://docs.workato.com/oem/oem-api/connections-parameters.html#"\
          "configuration-parameters-by-connector' " \
          "target='_blank'>provider </a> values pertaining " \
          'to the apps the customer account is allowed to access.' \
          'For more info about this feature, check out the '\
          "<a href = 'https://docs.workato.com/oem/admin-console/customers.html#settings'" \
          "target = '_blank'>OEM Admin Console - App Access</a> guide." },
        { name: 'frame_ancestors',
          hint: 'Provide one or more comma-separated frame ancestors.'\
          ' These URLs are used in the Content-Security-Policy HTTP '\
          'header to allow rendering of Workato IFrames.' },
        { name: 'time_zone', type: 'string',
          hint: 'Timezone name.'\
          " View this <a href='https://docs.workato.com/oem/oem-api/timezone-list.html' " \
          "target='_blank'>document </a> for a list of timezones. Defaults to PST if not"\
          ' specified.' },
        { name: 'in_trial',
          type: 'boolean', control_type: 'checkbox',
          hint: 'Downgrade or upgrade the user to/from a free'\
          ' plan and subscription plan',
          render_input: 'boolean_conversion',
          toggle_hint: 'Select from list',
          toggle_field: {
            name: 'in_trial', label: 'In trial',
            type: 'string', control_type: 'text',
            render_input: 'boolean_conversion',
            optional: true,
            toggle_hint: 'Use custom value',
            hint: 'Allowed values are: true, false'
          } },
        { name: 'auth_settings', label: 'Authentication settings', type: 'object',
          properties: [
            { name: 'type',
              control_type: 'select',
              pick_list: [['Workato auth', 'workato_auth'],
                          ['SAML SSO', 'saml_sso']],
              toggle_hint: 'Select from list',
              toggle_field: {
                name: 'type',
                label: 'Type',
                type: 'string',
                optional: true,
                control_type: 'text',
                toggle_hint: 'Use custom value',
                hint: 'Allowed values are: workato_auth,'\
                  ' saml_sso'
              } },
            { name: 'provider',
              control_type: 'select',
              pick_list: [%w[Okta okta],
                          %w[Onelogin onelogin],
                          %w[Others others]],
              toggle_hint: 'Select from list',
              toggle_field: {
                name: 'provider',
                label: 'Provider',
                type: 'string',
                optional: true,
                control_type: 'text',
                toggle_hint: 'Use custom value',
                hint: 'Allowed values are: okta,'\
                  ' onelogin, others'
              } },
            { name: 'metadata_url', label: 'Metadata URL' },
            { name: 'sso_url', label: 'SSO URL' },
            { name: 'saml_issuer', label: 'SAML issuer' },
            { name: 'x509_cert', label: 'X509 cert' },
            { name: 'jit_provisioning', label: 'JIT provisioning', type: 'boolean',
              control_type: 'checkbox',
              render_input: 'boolean_conversion',
              toggle_hint: 'Select from list',
              toggle_field: {
                name: 'jit_provisioning', label: 'JIT provisioning',
                type: 'string', control_type: 'text',
                render_input: 'boolean_conversion',
                optional: true,
                toggle_hint: 'Use custom value',
                hint: 'Allowed values are: true, false'
              } }
          ] },
        { name: 'task_limit_adjustment', type: 'string',
          hint: 'Task limit adjustment for current accounting period. ' \
          'Only valid for task-based plans. This adjustment will not ' \
          'apply to subsequent periods. Make a negative adjustment by ' \
          'adding "-" (eg. "-5000").' },
        { name: 'current_billing_period_start', type: 'date_time',
          control_type: 'date_time', convert_input: 'render_iso8601_timestamp',
          convert_output: 'date_time_conversion',
          hint: 'Set the current billing start date.' },
        { name: 'custom_task_limit', type: 'integer',
          hint: 'Overrides the current plan limit.',
          control_type: 'integer',
          convert_input: 'integer_conversion',
          convert_output: 'integer_conversion' },
        { name: 'page', type: 'integer', control_type: 'integer',
          sticky: true, convert_input: 'integer_conversion',
          convert_output: 'integer_conversion',
          hint: 'Page number. Defaults to 1.' },
        { name: 'per_page', type: 'integer', control_type: 'integer',
          sticky: true, convert_input: 'integer_conversion',
          convert_output: 'integer_conversion',
          hint: 'Page size. Defaults to 100 (maximum is 100).' }
      ]
    end,
    customer_accounts_output_schema: lambda do
      [
        { name: 'id', label: 'Customer account ID', type: 'integer',
          control_type: 'integer' }
      ].
        concat(call('customer_accounts_input_schema').
        ignored('id', 'page', 'per_page')).
        concat([{ name: 'trial', type: 'boolean' },
                { name: 'current_billing_period_end', type: 'date_time' },
                { name: 'task_limit', type: 'integer' },
                { name: 'task_count', type: 'integer' },
                { name: 'active_connection_limit', type: 'integer' },
                { name: 'active_connection_count', type: 'integer' },
                { name: 'active_recipe_count', type: 'integer' },
                { name: 'created_at', type: 'date_time' },
                { name: 'updated_at', type: 'date_time' },
                { name: 'billing_start_date', type: 'date_time' },
                { name: 'admin_notification_emails' },
                { name: 'error_notification_emails' }])
    end,
  },

  pick_lists: {
    api_mode: lambda do
      [
        %w[Projects projects],
        %w[Recipe\ Lifecycle\ Management rlcm],
        %w[Customer\ Workspace customer]
      ]
    end,
    workspace: lambda do
      [
        %w[Own\ Workspace own],
        %w[Customer\ Workspace customer]
      ]
    end,
    environments: lambda do |connection| 
      connection["workato_environments"].map do |env|
        ["#{env["name"]}", "#{env["name"]}"]
      end
    end,
    env_type: lambda do
      [
        %w[Test test],
        %w[Production prod]
      ]
    end, 
  }

}