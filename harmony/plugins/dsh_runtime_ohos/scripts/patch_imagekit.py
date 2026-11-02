"""仅打包时改写固定SHA原AttachmentStore；保留其它平台Sharp源码。"""
import hashlib

EXPECTED = 'cd39685581b4573a453c6126f8ce73da0bf1257c378827ebb431d6d4064f7662'
REPLACEMENTS = [('const requireSharp = createLazyRequire("sharp", import.meta.url);',
  'const requireSharp = createLazyRequire("sharp", import.meta.url);\n'
  'const OHOS_IMAGEKIT_ENABLED = /* OHOS_IMAGEKIT_GATE */ process.platform === "openharmony";\n'
  'let ohosImageModule;\n'
  'function ohosImageOperation(method, ...args) { return (ohosImageModule ??= '
  'import("./ohos-imagekit.mjs")).then(module => module[method](...args)); }'),
 ('async function probeImage(data) {',
  'async function probeImage(data) {\n'
  '\tif (OHOS_IMAGEKIT_ENABLED) return ohosImageOperation("probe", data);'),
 ('async function detectImage(data, limits) {',
  'async function detectImage(data, limits) {\n'
  '\tif (OHOS_IMAGEKIT_ENABLED) return ohosImageOperation("detect", data, limits);'),
 ('async function normalizeImage(data, detected, policy) {',
  'async function normalizeImage(data, detected, policy) {\n'
  '\tif (OHOS_IMAGEKIT_ENABLED) return ohosImageOperation("normalize", data, detected, policy);'),
 ('async function createRequestImage(attachment, target, hasAlpha) {',
  'async function createRequestImage(attachment, target, hasAlpha) {\n'
  '\tif (OHOS_IMAGEKIT_ENABLED) return ohosImageOperation("request", attachment, target);'),
 ('const REQUEST_IMAGE_TRANSFORM_VERSION = "request-image-v6";',
  'const REQUEST_IMAGE_TRANSFORM_VERSION = OHOS_IMAGEKIT_ENABLED ? "request-image-imagekit-candidate-v2" : '
  '"request-image-v6";'),
 ('await ensureDurableDirectory(home, parse(home).root);',
  'await ensureDurableDirectory(home, OHOS_IMAGEKIT_ENABLED ? await ohosImageOperation("durableBoundary", '
  'home) : parse(home).root);'),
 ('await link(staged.path, target);',
  'if (OHOS_IMAGEKIT_ENABLED) await ohosImageOperation("publishStaged", staged.path, target); else await '
  'link(staged.path, target);'),
 ('await unlink(staged.path);',
  'if (OHOS_IMAGEKIT_ENABLED) await removeTemporary(staged.path); else await unlink(staged.path);')]

def patch_attachment_source(source):
    if hashlib.sha256(source).hexdigest() != EXPECTED:
        raise ValueError("原AttachmentStore SHA不匹配，拒绝打包")
    text = source.decode("utf8")
    for before, after in REPLACEMENTS:
        if text.count(before) != 1: raise ValueError("图片适配源码锚点不唯一")
        text = text.replace(before, after)
    return text.encode("utf8")
