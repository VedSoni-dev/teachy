import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

/**
 * Stops any Teachy still running before a build.
 *
 * Without this, `npm run verify` fails the moment you have the app open — the
 * live sidecar holds Teachy.Platform.dll and MSBuild cannot overwrite it:
 *
 *   error MSB3027: Could not copy ... The file is locked by: "Teachy.Sidecar"
 *
 * That turns the edit-test loop into "remember to close the app first", which is
 * exactly the kind of friction that stops people running tests at all.
 */
const processNamesToStop = ['Teachy.Sidecar.exe', 'electron.exe'];

for (const processName of processNamesToStop) {
  try {
    await execFileAsync('taskkill', ['/IM', processName, '/F']);
    console.log(`stopped ${processName}`);
  } catch (taskkillError) {
    // Exit code 128 is "no such process", which is the normal case.
    const stderrText = String(taskkillError.stderr ?? '');
    if (/not found|not running/i.test(stderrText) || taskkillError.code === 128) {
      continue;
    }
    console.warn(`could not stop ${processName}: ${stderrText.trim() || taskkillError.message}`);
  }
}
