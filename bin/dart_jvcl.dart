import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:darty_json_safe/darty_json_safe.dart';
import 'package:dio/dio.dart';
import 'package:process_run/shell.dart';
import 'package:path/path.dart' as p;
import 'package:version/version.dart';

Future<void> main(List<String> args) async {
  final branch = getEnvironment('BRANCH');
  final mode = getEnvironment('MODE');
  final buildName = getEnvironment('BUILD_NAME');
  var buildId = int.parse(getEnvironment('BUILD_ID'));
  final commit = Platform.environment['LAST_BUILD_COMMIT'];
  if (commit != null) {
    final log = await loadGitLog(commit, branch);
    await saveLogToFile(log, branch);
  } else {
    final details = <JobDetail>[];
    JobDetail? logDetail;
    while (buildId > 0) {
      final detail = await getJobDetail(buildId);
      if (detail.gitCommit.isEmpty || detail.version.isEmpty) {
        buildId -= 1;
        continue;
      }
      details.add(detail);
      if (detail.isSuccess &&
          detail.branch == branch &&
          detail.mode == mode &&
          Version.parse(buildName) >= Version.parse(detail.version)) {
        logDetail = detail;
        break;
      } else {
        buildId -= 1;
      }
    }

    if (logDetail == null) {
      late int lastLogIndex;
      final lastSuccessIndex =
          details.lastIndexWhere((element) => element.isSuccess);
      if (lastSuccessIndex == -1) {
        lastLogIndex = details.lastIndexWhere((element) => !element.isSuccess);
      } else {
        lastLogIndex = min(details.length - 1, lastSuccessIndex + 1);
      }
      logDetail = details[lastLogIndex];
    }
    final log = logDetail.comments.join("\n");
    await saveLogToFile(log, branch);
  }
}

String getEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null) {
    throw 'please set $name environment';
  }
  return value;
}

Future<String> loadGitLog(String lastBuildCommit, String branch) async {
  final workspace = getEnvironment('WORKSPACE');
  final gitCommit = getEnvironment('GIT_COMMIT');
  final results = await Shell(workingDirectory: workspace).run('''
git log $lastBuildCommit..$gitCommit
''');
  final result = results.first;
  if (result.errText.isNotEmpty) {
    throw result.errText;
  }
  var logContent = '';
  for (var element in result.outLines) {
    if (element.contains('commit')) {
      continue;
    }
    logContent += element.replaceAll('    ', "");
  }
  return logContent;
}

Future<void> saveLogToFile(String logContent, String branch) async {
  final customLog = Platform.environment['GIT_LOG'];
  if (customLog != null) {
    logContent = """
$customLog
$logContent
""";
  }
  if (branch.isNotEmpty) {
    logContent = '''
代码分支: $branch
            
$logContent
''';
  }
  final mode = getEnvironment('MODE');
  if (mode == 'release') {
    logContent = getEnvironment('GIT_LOG');
  }
  print('''
当前日志:
$logContent
''');
  final pwd = getEnvironment('PWD');
  final logFile = File(p.join(pwd, 'git.log'));
  if (await logFile.exists()) {
    await logFile.delete();
  }
  await logFile.writeAsString(logContent);
}

Future<JobDetail> getJobDetail(int id) async {
  final url = buildUrl(id);
  final userName = getEnvironment('JENKINS_USERNAME');
  final password = getEnvironment('JENKINS_PASSWORD');
  final dio = Dio();
  final token = base64Encode(utf8.encode("$userName:$password"));
  dio.options.headers["Authorization"] = "Basic $token";
  try {
    final response = await dio.get(url);
    final result = JSON(response.data)['result'].stringValue;
    final isSuccess = result == 'SUCCESS';
    final actions = JSON(response.data)['actions'].listValue;
    final comments = JSON(response.data)['changeSet']['items']
        .listValue
        .map((e) => JSON(e)['comment'].stringValue)
        .toList();
    var branch = '';
    var mode = 'profile';
    var version = '';
    var gitCommit = '';
    for (final e in actions) {
      final className = JSON(e)['_class'].stringValue;
      if (className == 'hudson.model.ParametersAction') {
        final parameters = JSON(e)['parameters'].listValue;
        for (final e in parameters) {
          final name = JSON(e)['name'].stringValue;
          final value = JSON(e)['value'].stringValue;
          if (name == 'BRANCH') {
            branch = value;
          } else if (name == 'MODE') {
            mode = value;
          } else if (name == 'BUILD_NAME') {
            version = value;
          }
        }
      } else if (className == 'hudson.plugins.git.util.BuildData') {
        gitCommit = JSON(e)['lastBuiltRevision']['SHA1'].stringValue;
      }
    }
    return JobDetail(
      branch: branch,
      comments: comments,
      gitCommit: gitCommit,
      id: id,
      isSuccess: isSuccess,
      mode: mode,
      version: version,
    );
  } catch (e) {
    return JobDetail(
      id: id,
      branch: '',
      mode: '',
      version: '',
      gitCommit: '',
      isSuccess: false,
      comments: [],
    );
  }
}

String buildUrl(int id) {
  final jobUrl = getEnvironment('JOB_URL');
  return '$jobUrl$id/api/json?pretty=true';
}

class JobDetail {
  const JobDetail({
    required this.id,
    required this.branch,
    required this.mode,
    required this.version,
    required this.gitCommit,
    required this.isSuccess,
    required this.comments,
  });
  final int id;
  final String branch;
  final String mode;
  final String version;
  final String gitCommit;
  final bool isSuccess;
  final List<String> comments;
}
