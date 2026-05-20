; Template body — use function motions (mf, ]f, etc.) to navigate templates
(template
  (template_body
    "{"
    (_)* @function.inside
    "}")) @function.around

(html_comment)+ @comment.around
