import 'dart:convert';
import 'dart:io';
import 'package:darty_json_safe/darty_json_safe.dart';
import 'package:dio/dio.dart';
import 'package:process_run/shell.dart';
import 'package:path/path.dart' as p;
import 'package:version/version.dart';

Future<void> main(List<String> args) async {
  final branch = getEnvironment('BRANCH');
  final mode = getEnvironment('MODE');
  final buildName = getEnvironment('BUILD_NAME');
  final buildId = int.parse(getEnvironment('BUILD_ID'));
  final commit = Platform.environment['LAST_BUILD_COMMIT'];

  /// 如果制定上一次提交 则获取上一次提交到最新提交的日志 作为更新日志
  /// 否则就按照查询打包最近的打包号作为查询的上一次提交节点
  if (commit != null) {
    final log = await loadGitLog(commit, branch);
    await saveLogToFile(log, branch);
  } else {
    final details = <JobDetail>[];
    JobDetail? logDetail;

    var requestBuildId = buildId;

    /// 从上一个打包进行查询
    while (requestBuildId > 1) {
      requestBuildId -= 1;
      final detail = await getJobDetail(requestBuildId);
      if (detail.gitCommit.isEmpty || detail.version.isEmpty) {
        continue;
      }
      details.add(detail);
      if (detail.isSuccess &&
          detail.branch == branch &&
          detail.mode == mode &&
          Version.parse(buildName) >= Version.parse(detail.version)) {
        logDetail = detail;
        break;
      }
    }

    if (logDetail != null) {
      /// 查找到上次成功的节点
      final log = await loadGitLog(logDetail.gitCommit, branch);
      await saveLogToFile(log, branch);
    } else {
      /// 如果查找不到就获取当前节点的日志
      final detail = await getJobDetail(buildId);
      await saveLogToFile('''
commit ${detail.gitCommit}
${detail.comments.join('\n')}
''', branch);
    }
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
    if (element.startsWith('commit')) {
      logContent += '''

$element
''';
      continue;
    }
    if (element.contains('    ')) {
      final message = element.replaceAll('    ', "");
      if (message.isNotEmpty) {
        logContent += '''
$message
''';
      }
    }
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
    logContent = platformEnvironment['GIT_LOG'] ?? '';
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
  stdout.write('get detail: $url');
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
