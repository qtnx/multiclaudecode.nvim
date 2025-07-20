local M = {}

local uv = vim.loop

function M.create_notification_server(port, callback)
  local server = uv.new_tcp()
  server:bind("127.0.0.1", port)
  
  server:listen(128, function(err)
    if err then
      vim.notify("Failed to start notification server: " .. err, vim.log.levels.ERROR)
      return
    end
    
    local client = uv.new_tcp()
    server:accept(client)
    
    client:read_start(function(err, data)
      if err then
        client:close()
        return
      end
      
      if data then
        -- Parse HTTP request
        local body = data:match("\r\n\r\n(.+)$")
        if body then
          local ok, json = pcall(vim.json.decode, body)
          if ok then
            callback(json)
          end
        end
        
        -- Send HTTP response
        local response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        client:write(response, function()
          client:close()
        end)
      end
    end)
  end)
  
  return server
end

return M