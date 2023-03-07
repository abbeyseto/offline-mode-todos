import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:connectivity/connectivity.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

String host = '';

//Add entrypoint main function
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await Hive.deleteFromDisk();
  await Hive.initFlutter();
  Hive.registerAdapter(TodoAdapter());
  await Hive.openBox<Todo>('todos');
  Get.put(Connectivity());
  Get.put(Dio());
  runApp(const MyApp());

  // Change host depending on the platform
  TargetPlatform platform = defaultTargetPlatform;
  if (platform == TargetPlatform.iOS) {
    host = 'http://localhost:1337';
  } else if (platform == TargetPlatform.android) {
    host = 'http://10.0.2.2:1337';
  } else {
    host = 'http://localhost:1337';
  }
}

class TodoAdapter extends TypeAdapter<Todo> {
  TodoAdapter();

  @override
  Todo read(BinaryReader reader) {
    return Todo(
      id: reader.readString(),
      title: reader.readString(),
      completed: reader.readBool(),
    );
  }

  @override
  void write(BinaryWriter writer, Todo obj) {
    writer
      ..writeString(obj.id)
      ..writeString(obj.title)
      ..writeBool(obj.completed);
  }

  @override
  int get typeId => 0;
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Todo App on Web',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const TodoPage(),
    );
  }
}

class TodoPage extends StatefulWidget {
  const TodoPage({super.key});

  @override
  State<TodoPage> createState() => _TodoPageState();
}


class _TodoPageState extends State<TodoPage> {
  final TodoController _controller = Get.put(TodoController());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Todo App'),
      ),
      body: Obx(
        () => _controller.loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                itemCount: _controller.todos.length,
                itemBuilder: (_, index) {
                  final todo = _controller.todos[index];
                  return ListTile(
                    title: Text(todo.title),
                    leading: Checkbox(
                      value: todo.completed,
                      onChanged: (value) {
                        //get the index of the todo and update it
                        var indexOfItem = _controller.todos
                            .indexWhere((element) => element.id == todo.id);
                        _updateTodoCompleted(indexOfItem, value!);
                      },
                    ),
                    // add delete button
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () async {
                        await _controller.deleteTodoOnline(todo.id);
                      },
                    ),
                  );
                },
              ),

      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addTodo,
        tooltip: 'Add Todo',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _addTodo() async {
    final title = await _showAddTodoDialog();
    if (title != null) {
      final todo = Todo(
        id: "",
        title: title,
        completed: false,
      );
      await _controller.addTodoOnline(todo);
    }
  }

  Future<void> _updateTodoCompleted(int index, bool value) async {
    final todo = _controller.todos[index].copyWith(
      completed: value,
    );
    await _controller.updateTodoOnline(index, todo);
  }

  Future<String?> _showAddTodoDialog() async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: Get.context!,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add Todo'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Enter a todo title',
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Add'),
              onPressed: () {
                final title = controller.text.trim();
                if (title.isNotEmpty) {
                  Navigator.of(context).pop(title);
                }
              },
            ),
          ],
        );
      },
    );
  }
}

@HiveType(typeId: 0)
class Todo extends HiveObject {
  @HiveField(0)
  String title;
  @HiveField(1)
  bool completed;
  @HiveField(2)
  String id;
  @HiveField(3)
  bool deleted;
  @HiveField(4)
  bool edited;

  Todo({
    required this.id,
    required this.title,
    this.completed = false,
    this.deleted = false,
    this.edited = false,
  });

  Todo copyWith(
      {String? title,
      bool? completed,
      bool? deleted,
      bool? edited,
      String? id}) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      completed: completed ?? this.completed,
      deleted: deleted ?? this.deleted,
      edited: edited ?? this.edited,
    );
  }
}

class TodoDatabase {
  static const String _boxName = 'todos';

  Future<Box<Todo>> openBox() async {
    return await Hive.openBox<Todo>(_boxName);
  }

  Future<void> add(Todo todo) async {
    final box = await openBox();
    await box.add(todo);
  }

  Future<void> update(int index, Todo todo) async {
    final box = await openBox();
    await box.putAt(index, todo);
    print(box);
  }

  Future<void> delete(int index) async {
    final box = await openBox();
    final todo = box.getAt(index)!;
    await box.putAt(index, todo.copyWith(deleted: true));
  }

  Future<List<Todo>> getAll() async {
    final box = await openBox();
    return box.values.where((todo) => todo.deleted != false).toList();
    // return box.values.toList();
  }

  Future<void> addAll(List<Todo> todos) async {
    final box = await openBox();
    await box.addAll(todos);
  }
}

class TodoController extends GetxController {
  final TodoDatabase _todoDatabase = TodoDatabase();
  final Dio _dio = Dio();
  final _todos = <Todo>[].obs;
  final _loading = false.obs;

  List<Todo> get todos => _todos.toList();

  bool get loading => _loading.value;
  final Connectivity _connectivity = Connectivity();
  late StreamSubscription _streamSubscription;

  @override
  void onInit() {
    super.onInit();
    _init();
  }

  @override
  void onClose() {
    _streamSubscription.cancel();
    super.onClose();
  }

  Future<void> _init() async {
    _loading.value = true;
    _streamSubscription =
        _connectivity.onConnectivityChanged.listen((event) async {
      if (event != ConnectivityResult.none) {
        await _syncTodos();
        Timer.periodic(const Duration(seconds: 30), (timer) async {
          print('syncing todos with server...');
          await _syncTodos();
        });
        // show snackbar if there is internet connection and close it in 10 seconds
        Get.snackbar(
          'Application Online!',
          'Data sync will resume every 30 seconds',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.grey[800],
          colorText: Colors.white,
          dismissDirection: DismissDirection.horizontal,
          duration: const Duration(seconds: 10),
          isDismissible: true,
          snackStyle: SnackStyle.GROUNDED,
        );
      }
      // show snackbar if there is no internet connection
      else {
        Get.snackbar(
          'Offline Mode activated!',
          'No Internet Connection, data sync will resume once you are connected to the internet',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.grey[800],
          colorText: Colors.white,
          isDismissible: true,
          dismissDirection: DismissDirection.horizontal,
          duration: const Duration(seconds: 10),
          snackStyle: SnackStyle.GROUNDED,
        );
      }
    });
    _loading.value = false;
  }

  Future<void> _getTodos() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult != ConnectivityResult.none) {
      try {
        final response = await _dio.get('$host/api/todos',
            options: Options(
              headers: {
                'cache-control': 'no-cache',
                'content-type': 'application/json',
                'Access-Control-Allow-Origin': '*',
              },
            ));

        final todos = (response.data['data'] as List)
            .map((e) => Todo(
                  id: e['id'].toString(),
                  title: e['attributes']['title'],
                  completed: e['attributes']['completed'],
                  deleted: false,
                  edited: false,
                ))
            .toList();
        _todos.assignAll(todos);
        _todoDatabase.addAll(todos);
        _loading.value = false;
      } catch (e) {
        if (kDebugMode) {
          print("PRINTING ERROR: $e");
          _loading.value = false;
        }
      }
    } else {
      final todos = await _todoDatabase.getAll();
      _todos.assignAll(todos);
      _loading.value = false;
    }
  }

  Future<void> _syncTodos() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult != ConnectivityResult.none) {
      final todos = _todos.toList();
      for (var i = 0; i < todos.length; i++) {
        final todo = todos[i];
        if (todo.deleted) {
          await deleteTodoOnline(todo.id);
        } else if (todo.edited) {
          if (todo.id.isEmpty) {
            await addTodoOnline(todo);
          } else {
            await updateTodoOnline(i, todo);
          }
        }
      }
      await _getTodos();
    } else {
      print('no internet connection...');
    }
  }

  addTodoOffline(Todo todo) {
    print("ADDING TODO OFFLINE");
    _todos.add(todo);
    _todoDatabase.add(todo);
  }

  updateTodoOffline(int index, todo) {
    print("UPDATING TODO OFFLINE");
    _todos[index] = todo;
    _todoDatabase.update(index, todo);
  }

  Future<void> updateTodoOnline(index, todo) async {
    print("UPDATING TODO ONLINE");
    // convert todo.id to int
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      updateTodoOffline(index, todo.copyWith(edited: true));
    } else {
      final id = int.parse(todo.id);
      final response = await _dio.put('$host/api/todos/$id', data: {
        'data': {
          'title': todo.title,
          'completed': todo.completed,
        }
      });
      print("RESPONSE FROM UPDATE: $response");
      if (response.data['data']['id'] != null) {
        final updatedTodo = todo.copyWith(edited: false);
        final index = _todos.indexWhere((element) => element.id == todo.id);
        _todos[index] = updatedTodo;
        _todoDatabase.update(index, updatedTodo);
      } else {
        final updatedTodo = todo.copyWith(edited: true);
        final index = _todos.indexWhere((element) => element.id == todo.id);
        _todos[index] = updatedTodo;
        _todoDatabase.update(index, updatedTodo);
      }
    }
  }

  Future<void> addTodoOnline(todo) async {
    print("ADDING TODO ONLINE");
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      addTodoOffline(todo.copyWith(edited: true));
    } else {
      final response = await _dio.post('$host/api/todos',
          data: {
            'data': {
              'title': todo.title,
              'completed': todo.completed,
            }
          },
          options: Options(
            headers: {
              'cache-control': 'no-cache',
              'content-type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            },
          ));
      print("RESPONSE FROM ADD: $response");
      if (response.data['data']['id'] != null) {
        final id = response.data['data']['id'].toString();
        final updatedTodo = todo.copyWith(
            id: id,
            edited: false,
            deleted: false,
            completed: false,
            title: response.data['data']['title']);
        addTodoOffline(updatedTodo);
      } else {
        final updatedTodo = todo.copyWith(edited: true);
        updateTodoOffline(_todos.indexOf(todo), updatedTodo);
      }
    }
  }

  Future<void> deleteTodoOffline(int index) async {
    _todos.removeAt(index);
    // update todo offline with deleted: true
    await _todoDatabase.update(index, _todos[index].copyWith(deleted: true));
    // _todoDatabase.delete(index);
  }

  Future<void> deleteTodoOnline(String id) async {
    print("DELETING TODO ONLINE");
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      final index = _todos.indexWhere((element) => element.id == id);
      deleteTodoOffline(index);
      // _todos.removeAt(index);
    } else {
      // convert id to int
      final intId = int.parse(id);
      final response = await _dio.delete('$host/api/todos/$intId',
          options: Options(
            headers: {
              'cache-control': 'no-cache',
              'content-type': 'application/json'
            },
          ));

      print("RESPONSE FROM DELETE: $response");
      // if response.data['data']['id'] is not null, then delete todo offline
      // else, update todo offline with deleted = true
      if (response.data['data']['id'] != null) {
        final index = _todos.indexWhere((element) => element.id == id);
        await deleteTodoOffline(index);
      }
    }
  }

  Future<void> deleteTodoOnlineAndOffline(String id, int index) async {
    await deleteTodoOnline(id);
    await deleteTodoOffline(index);
  }
}
