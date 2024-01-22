import fs from "fs";
import path from "path";

const currPath = import.meta.dir;
const srcPath = `${currPath}/src`;
const buildPath = `${currPath}/../build/frontend`;

const ensureDirectoryExistence = (filePath) => {
  const dirname = path.dirname(filePath);
  if (fs.existsSync(dirname)) {
    return true;
  }
  ensureDirectoryExistence(dirname);
  fs.mkdirSync(dirname, { recursive: true });
};

const transpileTsFile = async (srcFilePath, destFilePath) => {
  const code = await Bun.file(srcFilePath).text();
  const transpiler = new Bun.Transpiler({ loader: "ts" });
  const result = transpiler.transformSync(code);
  ensureDirectoryExistence(destFilePath);
  fs.writeFileSync(destFilePath, result, 'utf8');
};

const copyFile = (srcFilePath, destFilePath) => {
  ensureDirectoryExistence(destFilePath);
  fs.copyFileSync(srcFilePath, destFilePath);
};

const processFile = async (srcFilePath) => {
  const destFilePath = srcFilePath.replace(srcPath, buildPath).replace(/\.ts$/, '.js');
  if (srcFilePath.endsWith('.ts')) {
    await transpileTsFile(srcFilePath, destFilePath);
  } else if (!srcFilePath.endsWith('.js')) {
    copyFile(srcFilePath, destFilePath);
  }
};

const processDirectory = (dirPath) => {
  fs.readdirSync(dirPath).forEach(async file => {
    const fullPath = `${dirPath}/${file}`;
    if (fs.lstatSync(fullPath).isDirectory()) {
      processDirectory(fullPath);
    } else {
      await processFile(fullPath);
    }
  });
};

const deleteBuildFiles = () => {
  if (fs.existsSync(buildPath)) {
    fs.rmSync(buildPath, { recursive: true, force: true });
  }
};

deleteBuildFiles();
processDirectory(srcPath);

let lastProcessed = Date.now();

const watcher = fs.watch(srcPath, { recursive: true }, async (event, filename) => {
  const filePath = `${srcPath}/${filename}`;
  const now = Date.now();
  if (now - lastProcessed < 200) {
    return;
  }
  lastProcessed = now;
  console.log(`Detected ${event} in ${filePath}`);
  await processFile(filePath);
});
