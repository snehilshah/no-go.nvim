local M = {}

M.error_query = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      (return_statement
        (expression_list
          (identifier) @return_identifier)?)) @collapse_block) @if_statement
)
]]

M.import_query = [[
(import_declaration
  (import_spec_list) @import_list) @import_block
]]

return M
