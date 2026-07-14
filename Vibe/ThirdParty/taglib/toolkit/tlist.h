/***************************************************************************
    copyright            : (C) 2002 - 2008 by Scott Wheeler
    email                : wheeler@kde.org
 ***************************************************************************/

/***************************************************************************
 *   This library is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU Lesser General Public License version   *
 *   2.1 as published by the Free Software Foundation.                     *
 *                                                                         *
 *   This library is distributed in the hope that it will be useful, but   *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   Lesser General Public License for more details.                       *
 *                                                                         *
 *   You should have received a copy of the GNU Lesser General Public      *
 *   License along with this library; if not, write to the Free Software   *
 *   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA         *
 *   02110-1301  USA                                                       *
 *                                                                         *
 *   Alternatively, this file is available under the Mozilla Public        *
 *   License Version 1.1.  You may obtain a copy of the License at         *
 *   http://www.mozilla.org/MPL/                                           *
 ***************************************************************************/

#ifndef TAGLIB_LIST_H
#define TAGLIB_LIST_H

#include <list>
#include <initializer_list>
#include <memory>

namespace TagLib {

  //! A generic, implicitly shared list.

  /*!
   * This is a basic generic list that's somewhere between a std::list and a
   * QList.  This class is implicitly shared.  For example:
   *
   * \code
   *
   * TagLib::List<int> l = someOtherIntList;
   *
   * \endcode
   *
   * The above example is very cheap.  This also makes lists suitable as
   * return types of functions.  The above example will just copy a pointer rather
   * than copying the data in the list.  When your \e shared list's data changes,
   * only \e then will the data be copied.
   */

  template <class T> class List
  {
  public:
#ifndef DO_NOT_DOCUMENT
    using Iterator = typename std::list<T>::iterator;
    using ConstIterator = typename std::list<T>::const_iterator;
#endif

    /*!
     * Constructs an empty list.
     */
    List();

    /*!
     * Make a shallow, implicitly shared, copy of \a l.  Because this is
     * implicitly shared, this method is lightweight and suitable for
     * pass-by-value usage.
     */
    List(const List<T> &l);

    /*!
     * Construct a List with the contents of the braced initializer list.
     */
    List(std::initializer_list<T> init);

    /*!
     * Destroys this List instance.  If auto deletion is enabled and this list
     * contains a pointer type, all of the members are also deleted.
     */
    ~List();

    /*!
     * Returns an STL style iterator to the beginning of the list.  See
     * \c std::list::const_iterator for the semantics.
     */
    Iterator begin();

    /*!
     * Returns an STL style constant iterator to the beginning of the list.  See
     * \c std::list::iterator for the semantics.
     */
    ConstIterator begin() const;

    /*!
     * Returns an STL style constant iterator to the beginning of the list.  See
     * \c std::list::iterator for the semantics.
     */
    ConstIterator cbegin() const;

    /*!
     * Returns an STL style iterator to the end of the list.  See
     * \c std::list::iterator for the semantics.
     */
    Iterator end();

    /*!
     * Returns an STL style constant iterator to the end of the list.  See
     * \c std::list::const_iterator for the semantics.
     */
    ConstIterator end() const;

    /*!
     * Returns an STL style constant iterator to the end of the list.  See
     * \c std::list::const_iterator for the semantics.
     */
    ConstIterator cend() const;

    /*!
     * Inserts a copy of \a item before \a it.
     *
     * \note This method cannot detach because \a it is tied to the internal
     * list.  Do not make an implicitly shared copy of this list between
     * getting the iterator and calling this method!
     */
    Iterator insert(Iterator it, const T &item);

    /*!
     * Inserts the \a value into the list.  This assumes that the list is
     * currently sorted.  If \a unique is \c true then the value will not
     * be inserted if it is already in the list.
     */
    List<T> &sortedInsert(const T &value, bool unique = false);

    /*!
     * Appends \a item to the end of the list and returns a reference to the
     * list.
     */
    List<T> &append(const T &item);

    /*!
     * Appends all of the values in \a l to the end of the list and returns a
     * reference to the list.
     */
    List<T> &append(const List<T> &l);

    /*!
     * Prepends \a item to the beginning list and returns a reference to the
     * list.
     */
    List<T> &prepend(const T &item);

    /*!
     * Prepends all of the items in \a l to the beginning list and returns a
     * reference to the list.
     */
    List<T> &prepend(const List<T> &l);

    /*!
     * Clears the list.  If auto deletion is enabled and this list contains a
     * pointer type the members are also deleted.
     *
     * \see setAutoDelete()
     */
    List<T> &clear();

    /*!
     * Returns the number of elements in the list.
     *
     * \see isEmpty()
     */
    unsigned int size() const;

    /*!
     * Returns whether or not the list is empty.
     *
     * \see size()
     */
    bool isEmpty() const;

    /*!
     * Find the first occurrence of \a value.
     */
    Iterator find(const T &value);

    /*!
     * Find the first occurrence of \a value.
     */
    ConstIterator find(const T &value) const;

    /*!
     * Find the first occurrence of \a value.
     */
    ConstIterator cfind(const T &value) const;

    /*!
     * Returns \c true if the list contains \a value.
     */
    bool contains(const T &value) const;

    /*!
     * Erase the item at \a it from the list.
     *
     * \note This method cannot detach because \a it is tied to the internal
     * list.  Do not make an implicitly shared copy of this list between
     * getting the iterator and calling this method!
     */
    Iterator erase(Iterator it);

    /*!
     * Returns a reference to the first item in the list.
     */
    const T &front() const;

    /*!
     * Returns a reference to the first item in the list.
     */
    T &front();

    /*!
     * Returns a reference to the last item in the list.
     */
    const T &back() const;

    /*!
     * Returns a reference to the last item in the list.
     */
    T &back();

    /*!
     * Auto delete the members of the list when the last reference to the list
     * passes out of scope.  This will have no effect on lists which do not
     * contain a pointer type.
     *
     * \note This relies on partial template instantiation -- most modern C++
     * compilers should now support this.
     */
    void setAutoDelete(bool autoDelete);

    /*!
     * Returns \c true if auto-deletion is enabled.
     */
    bool autoDelete() const;

    /*!
     * Returns a reference to item \a i in the list.
     *
     * \warning This method is slow.  Use iterators to loop through the list.
     */
    T &operator[](unsigned int i);

    /*!
     * Returns a const reference to item \a i in the list.
     *
     * \warning This method is slow.  Use iterators to loop through the list.
     */
    const T &operator[](unsigned int i) const;

    /*!
     * Make a shallow, implicitly shared, copy of \a l.  Because this is
     * implicitly shared, this method is lightweight and suitable for
     * pass-by-value usage.
     */
    List<T> &operator=(const List<T> &l);

    /*!
     * Replace the contents of the list with those of the braced initializer list.
     *
     * If auto deletion is enabled and the list contains a pointer type, the members are also deleted
     */
    List<T> &operator=(std::initializer_list<T> init);

    /*!
     * Exchanges the content of this list with the content of \a l.
     */
    void swap(List<T> &l) noexcept;

    /*!
     * Compares this list with \a l and returns \c true if all of the elements are
     * the same.
     */
    bool operator==(const List<T> &l) const;

    /*!
     * Compares this list with \a l and returns \c true if the lists differ.
     */
    bool operator!=(const List<T> &l) const;

    /*!
     * Sorts this list in ascending order using operator< of T.
     */
    void sort();

    /*!
     * Sorts this list in ascending order using the comparison
     * function object \a comp which returns \c true if the first argument is
     * less than the second.
     */
    template<class Compare>
    void sort(Compare&& comp);

  protected:
    /*!
     * If this List is being shared via implicit sharing, do a deep copy of the
     * data and separate from the shared members.  This should be called by all
     * non-const subclass members without Iterator parameters.
     */
    void detach();

  private:
#ifndef DO_NOT_DOCUMENT
    template <class TP> class ListPrivate;
    std::shared_ptr<ListPrivate<T>> d;
#endif
  };

}  // namespace TagLib

// Since GCC doesn't support the "export" keyword, we have to include the
// implementation.

// #include "tlist.tcc.h"

/***************************************************************************
    copyright            : (C) 2002 - 2008 by Scott Wheeler
    email                : wheeler@kde.org
 ***************************************************************************/

/***************************************************************************
 *   This library is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU Lesser General Public License version   *
 *   2.1 as published by the Free Software Foundation.                     *
 *                                                                         *
 *   This library is distributed in the hope that it will be useful, but   *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   Lesser General Public License for more details.                       *
 *                                                                         *
 *   You should have received a copy of the GNU Lesser General Public      *
 *   License along with this library; if not, write to the Free Software   *
 *   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA         *
 *   02110-1301  USA                                                       *
 *                                                                         *
 *   Alternatively, this file is available under the Mozilla Public        *
 *   License Version 1.1.  You may obtain a copy of the License at         *
 *   http://www.mozilla.org/MPL/                                           *
 ***************************************************************************/

#include <algorithm>
#include <memory>

namespace TagLib {

////////////////////////////////////////////////////////////////////////////////
// public members
////////////////////////////////////////////////////////////////////////////////

// The functionality of List<T>::setAutoDelete() is implemented here partial
// template specialization.  This is implemented in such a way that calling
// setAutoDelete() on non-pointer types will simply have no effect.

// A base for the generic and specialized private class types.  New
// non-templatized members should be added here.

class ListPrivateBase
{
public:
  bool autoDelete{};
};

// A generic implementation

template <class T>
template <class TP> class List<T>::ListPrivate  : public ListPrivateBase
{
public:
  using ListPrivateBase::ListPrivateBase;
  ListPrivate(const std::list<TP> &l) : list(l) {}
  ListPrivate(std::initializer_list<TP> init) : list(init) {}
  void clear() {
    list.clear();
  }
  std::list<TP> list;
};

// A partial specialization for all pointer types that implements the
// setAutoDelete() functionality.

template <class T>
template <class TP> class List<T>::ListPrivate<TP *> : public ListPrivateBase
{
public:
  using ListPrivateBase::ListPrivateBase;
  ListPrivate(const std::list<TP *> &l) : list(l) {}
  ListPrivate(std::initializer_list<TP *> init) : list(init) {}
  ~ListPrivate() {
    clear();
  }
  ListPrivate(const ListPrivate &) = delete;
  ListPrivate &operator=(const ListPrivate &) = delete;
  void clear() {
    if(autoDelete) {
      for(auto &m : list)
        delete m;
    }
    list.clear();
  }
  std::list<TP *> list;
};

////////////////////////////////////////////////////////////////////////////////
// public members
////////////////////////////////////////////////////////////////////////////////

template <class T>
List<T>::List() :
  d(std::make_shared<ListPrivate<T>>())
{
}

template <class T>
List<T>::List(const List<T> &) = default;

template <class T>
List<T>::List(std::initializer_list<T> init) :
  d(std::make_shared<ListPrivate<T>>(init))
{
}

template <class T>
List<T>::~List() = default;

template <class T>
typename List<T>::Iterator List<T>::begin()
{
  detach();
  return d->list.begin();
}

template <class T>
typename List<T>::ConstIterator List<T>::begin() const
{
  return d->list.begin();
}

template <class T>
typename List<T>::ConstIterator List<T>::cbegin() const
{
  return d->list.cbegin();
}

template <class T>
typename List<T>::Iterator List<T>::end()
{
  detach();
  return d->list.end();
}

template <class T>
typename List<T>::ConstIterator List<T>::end() const
{
  return d->list.end();
}

template <class T>
typename List<T>::ConstIterator List<T>::cend() const
{
  return d->list.cend();
}

template <class T>
typename List<T>::Iterator List<T>::insert(Iterator it, const T &item)
{
  return d->list.insert(it, item);
}

template <class T>
List<T> &List<T>::sortedInsert(const T &value, bool unique)
{
  detach();
  Iterator it = begin();
  while(it != end() && *it < value)
    ++it;
  if(unique && it != end() && *it == value)
    return *this;
  insert(it, value);
  return *this;
}

template <class T>
List<T> &List<T>::append(const T &item)
{
  detach();
  d->list.push_back(item);
  return *this;
}

template <class T>
List<T> &List<T>::append(const List<T> &l)
{
  detach();
  d->list.insert(d->list.end(), l.begin(), l.end());
  return *this;
}

template <class T>
List<T> &List<T>::prepend(const T &item)
{
  detach();
  d->list.push_front(item);
  return *this;
}

template <class T>
List<T> &List<T>::prepend(const List<T> &l)
{
  detach();
  d->list.insert(d->list.begin(), l.begin(), l.end());
  return *this;
}

template <class T>
List<T> &List<T>::clear()
{
  detach();
  d->clear();
  return *this;
}

template <class T>
unsigned int List<T>::size() const
{
  return static_cast<unsigned int>(d->list.size());
}

template <class T>
bool List<T>::isEmpty() const
{
  return d->list.empty();
}

template <class T>
typename List<T>::Iterator List<T>::find(const T &value)
{
  detach();
  return std::find(d->list.begin(), d->list.end(), value);
}

template <class T>
typename List<T>::ConstIterator List<T>::find(const T &value) const
{
  return std::find(d->list.begin(), d->list.end(), value);
}

template <class T>
typename List<T>::ConstIterator List<T>::cfind(const T &value) const
{
  return std::find(d->list.cbegin(), d->list.cend(), value);
}

template <class T>
bool List<T>::contains(const T &value) const
{
  return std::find(d->list.begin(), d->list.end(), value) != d->list.end();
}

template <class T>
typename List<T>::Iterator List<T>::erase(Iterator it)
{
  return d->list.erase(it);
}

template <class T>
const T &List<T>::front() const
{
  return d->list.front();
}

template <class T>
T &List<T>::front()
{
  detach();
  return d->list.front();
}

template <class T>
const T &List<T>::back() const
{
  return d->list.back();
}

template <class T>
void List<T>::setAutoDelete(bool autoDelete)
{
  detach();
  d->autoDelete = autoDelete;
}

template <class T>
bool List<T>::autoDelete() const
{
  return d->autoDelete;
}

template <class T>
T &List<T>::back()
{
  detach();
  return d->list.back();
}

template <class T>
T &List<T>::operator[](unsigned int i)
{
  auto it = d->list.begin();
  std::advance(it, i);

  return *it;
}

template <class T>
const T &List<T>::operator[](unsigned int i) const
{
  auto it = d->list.begin();
  std::advance(it, i);

  return *it;
}

template <class T>
List<T> &List<T>::operator=(const List<T> &) = default;

template <class T>
List<T> &List<T>::operator=(std::initializer_list<T> init)
{
  bool autoDeleteEnabled = d->autoDelete;
  List(init).swap(*this);
  setAutoDelete(autoDeleteEnabled);
  return *this;
}

template <class T>
void List<T>::swap(List<T> &l) noexcept
{
  using std::swap;

  swap(d, l.d);
}

template <class T>
bool List<T>::operator==(const List<T> &l) const
{
  return d->list == l.d->list;
}

template <class T>
bool List<T>::operator!=(const List<T> &l) const
{
  return d->list != l.d->list;
}

template <class T>
void List<T>::sort()
{
  detach();
  d->list.sort();
}

template <class T>
template <class Compare>
void List<T>::sort(Compare&& comp)
{
  detach();
  d->list.sort(std::forward<Compare>(comp));
}

////////////////////////////////////////////////////////////////////////////////
// protected members
////////////////////////////////////////////////////////////////////////////////

template <class T>
void List<T>::detach()
{
  if(d.use_count() > 1) {
    d = std::make_shared<ListPrivate<T>>(d->list);
  }
}

} // namespace TagLib


#endif
